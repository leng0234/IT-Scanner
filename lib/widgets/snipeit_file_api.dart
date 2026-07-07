import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../../models/asset_model.dart';
import 'html_entity_utils.dart';
import 'prior_checkout_record.dart';

/// All HTTP calls against Snipe-IT's `/hardware/{id}/files` endpoints:
/// uploading the signed PDF, stashing the checkout signature so it can be
/// recovered on checkin, looking that record back up, and cleaning up the
/// old checkout artifacts once an asset is checked back in.
///
/// Pulled out of the dialog widget so the network/parsing logic can be
/// read, tested, and debugged independently of the UI.
class SnipeItFileApi {
  const SnipeItFileApi();

  /// Reads `SNIPEIT_BASE_URL` / `SNIPEIT_API_TOKEN` from the `.env` file.
  /// Returns null if either is missing/empty.
  ({String baseUrl, String token})? _credentials() {
    final baseUrl = dotenv.env['SNIPEIT_BASE_URL'];
    final token = dotenv.env['SNIPEIT_API_TOKEN'];
    if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
      return null;
    }
    return (baseUrl: baseUrl, token: token);
  }

  Map<String, String> _headers(String token) => {
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
      };

  // ── Upload the signed PDF ────────────────────────────────────────────────
  //
  // Snipe-IT's /hardware/{id}/files endpoint can return HTTP 200 while the
  // JSON body itself says `"status": "error"` (e.g. wrong field name,
  // missing permission, bad asset id). Checking only the HTTP status code
  // would treat those in-body errors as success, so the JSON body's
  // `status` field is checked too. The multipart field name is `file[]`
  // (array form), which is what Snipe-IT's file upload endpoint expects.
  Future<void> uploadPdf({
    required Uint8List pdfBytes,
    required String action,
    required AssetModel asset,
    required String? assigneeName,
  }) async {
    final assetId = asset.id;
    if (assetId == null) {
      throw Exception('Asset ID is missing. Cannot upload to Snipe-IT.');
    }

    final creds = _credentials();
    if (creds == null) {
      throw Exception('Snipe-IT URL or Token not found in .env '
          '(check keys SNIPEIT_BASE_URL / SNIPEIT_API_TOKEN)');
    }

    final uri = Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');

    final now = DateTime.now();
    final dateString =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final fileName =
        '${asset.assetTag ?? 'Asset'}_${assigneeName ?? 'User'}_${dateString}_$action.pdf';

    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_headers(creds.token));
    request.files.add(
      http.MultipartFile.fromBytes('file[]', pdfBytes, filename: fileName),
    );
    request.fields['notes'] =
        '$action document signed by ${assigneeName ?? 'Unknown'}';

    final streamedResponse = await request.send();
    final respStr = await streamedResponse.stream.bytesToString();

    debugPrint('=== [Upload] HTTP ${streamedResponse.statusCode}: $respStr');

    if (streamedResponse.statusCode != 200) {
      throw Exception(
          'Failed to upload: HTTP ${streamedResponse.statusCode} - $respStr');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(respStr) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Unexpected response from Snipe-IT: $respStr');
    }

    final status = json['status']?.toString().toLowerCase();
    if (status == 'error') {
      final messages = json['messages'];
      throw Exception('Snipe-IT rejected the upload: $messages');
    }

    debugPrint('=== [Upload] Success: PDF uploaded for Asset ID $assetId');
  }

  // ── Save checkout signature separately (for later reuse on checkin) ──────
  //
  // When checking a device OUT, we additionally upload just the signature
  // PNG (not the whole PDF) as its own small file attached to the asset,
  // tagged with a recognizable filename marker
  // (`_checkout_signature_<assetId>.png`) and with the recipient's
  // name/division/date packed as JSON into that file's `notes` field.
  //
  // Later, when the SAME asset is checked back IN, [fetchPriorCheckoutRecord]
  // looks this file up and downloads it, so the "Receive" box on the checkin
  // PDF is filled in automatically instead of printing a blank placeholder
  // — no local storage needed, Snipe-IT itself is the storage.
  //
  // Deliberately best-effort: if it fails, we only log it and move on,
  // since a failure here must never block the checkout flow the user is
  // actually waiting on. Callers should still `await` this (rather than
  // fire-and-forget) so a checkin started moments later doesn't race an
  // in-flight upload and see it as "missing".
  Future<void> uploadCheckoutSignature({
    required Uint8List sigBytes,
    required AssetModel asset,
    required String dateStr,
    required String? assigneeName,
    String? division,
  }) async {
    final assetId = asset.id;
    if (assetId == null) return;

    final creds = _credentials();
    if (creds == null) {
      debugPrint('=== [CheckoutSignature Upload] skipped: missing .env config');
      return;
    }

    try {
      final uri = Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final fileName = '_checkout_signature_$assetId.png';

      final metaNotes = jsonEncode({
        'assigneeName': assigneeName ?? '—',
        'division': division,
        'dateStr': dateStr,
      });

      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(_headers(creds.token));
      request.files.add(
        http.MultipartFile.fromBytes('file[]', sigBytes, filename: fileName),
      );
      request.fields['notes'] = metaNotes;

      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      debugPrint(
          '=== [CheckoutSignature Upload] HTTP ${streamed.statusCode}: $body');
    } catch (e, st) {
      debugPrint('=== [CheckoutSignature Upload] error: $e\n$st');
    }
  }

  // ── Look up the checkout signature saved above (for checkin PDFs) ────────
  //
  // CONFIRMED RESPONSE SHAPE (from live debug log on 2026-07-03): Snipe-IT's
  // file-listing calls return:
  //   { "status": "success", "payload": { "total": N, "rows": [ {
  //       "id": 66, "filename": "...", "note": "...", ...
  //   } ] } }
  // Files live under `GET /hardware/{id}/files` (NOT embedded in the plain
  // asset-detail response), and the per-file note key is `note` (singular),
  // not `notes`. A couple of alternate shapes are still checked as a
  // fallback in case of version differences, so this degrades to returning
  // null (blank checkout box) instead of crashing if your instance differs.
  //
  // Matching is done primarily via the `note` JSON payload (which we
  // control and Snipe-IT does not rewrite), with a looser,
  // separator-agnostic filename check as a fallback — Snipe-IT renames
  // every uploaded file on its own (prefixes "asset-{id}-{randomhash}-" and
  // converts underscores to hyphens), so matching on the exact original
  // filename substring does not work.
  Future<PriorCheckoutRecord?> fetchPriorCheckoutRecord({
    required int assetId,
    required String? assigneeName,
    String? division,
  }) async {
    final creds = _credentials();
    if (creds == null) return null;
    final headers = _headers(creds.token);

    try {
      final filesUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final filesResp = await http.get(filesUri, headers: headers);
      if (filesResp.statusCode != 200) {
        debugPrint('=== [PriorCheckout] failed to fetch files list: '
            'HTTP ${filesResp.statusCode}');
        return null;
      }

      final rawFiles = _extractFileRows(filesResp.body);
      if (rawFiles == null) {
        debugPrint('=== [PriorCheckout] no files found in response: '
            '${filesResp.body}');
        return null;
      }

      final match = _findCheckoutSignatureFile(rawFiles);
      if (match == null) {
        debugPrint('=== [PriorCheckout] no checkout-signature file found '
            'among ${rawFiles.length} file(s)');
        return null;
      }

      final fileId = match['id'];
      if (fileId == null) return null;

      final fileUri = Uri.parse(
          '${creds.baseUrl}/api/v1/hardware/$assetId/files/$fileId');
      final fileResp = await http.get(fileUri, headers: headers);
      if (fileResp.statusCode != 200 || fileResp.bodyBytes.isEmpty) {
        debugPrint('=== [PriorCheckout] failed to download file $fileId: '
            'HTTP ${fileResp.statusCode}');
        return null;
      }

      // Recover assignee/division/date, packed as JSON into the file's
      // note when it was uploaded. Snipe-IT returns this back as `note`
      // (singular) even though the upload field is named `notes` — check
      // both. `dateStr` has no fallback other than '—': it's the field
      // that actually restores the checkout date on the checkin PDF.
      String? recoveredName;
      String? recoveredDivision;
      String? recoveredDate;
      final noteValue = (match['note'] ?? match['notes'])?.toString();
      if (noteValue != null && noteValue.isNotEmpty) {
        try {
          final meta = jsonDecode(HtmlEntityUtils.decode(noteValue))
              as Map<String, dynamic>;
          recoveredName = meta['assigneeName']?.toString();
          recoveredDivision = meta['division']?.toString();
          recoveredDate = meta['dateStr']?.toString();
        } catch (_) {
          // note wasn't our JSON payload (e.g. edited manually) — ignore.
        }
      }

      return PriorCheckoutRecord(
        assigneeName: recoveredName ?? assigneeName ?? '—',
        division: recoveredDivision ?? division,
        dateStr: recoveredDate ?? '—',
        sigBytes: fileResp.bodyBytes,
      );
    } catch (e, st) {
      debugPrint('=== [PriorCheckout] lookup failed: $e\n$st');
      return null;
    }
  }

  // ── Clean up checkout artifacts once checked back in ──────────────────────
  //
  // After a successful CHECKIN, delete the two files that were uploaded
  // during the matching CHECKOUT — the checkout PDF and the standalone
  // checkout-signature PNG — so Snipe-IT ends up holding just this one
  // checkin PDF instead of accumulating a growing pile of files every
  // checkout/checkin cycle.
  //
  // Deliberately best-effort: this only runs *after* the checkin PDF has
  // already uploaded successfully, so a failure here must never surface as
  // a failed checkin — it's just log-and-move-on cleanup.
  Future<void> deleteCheckoutArtifacts(int assetId) async {
    final creds = _credentials();
    if (creds == null) {
      debugPrint('=== [DeleteCheckoutArtifacts] skipped: missing .env config');
      return;
    }
    final headers = _headers(creds.token);

    try {
      final filesUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final filesResp = await http.get(filesUri, headers: headers);
      if (filesResp.statusCode != 200) {
        debugPrint('=== [DeleteCheckoutArtifacts] failed to fetch files '
            'list: HTTP ${filesResp.statusCode}');
        return;
      }

      final rawFiles = _extractFileRows(filesResp.body);
      if (rawFiles == null) {
        debugPrint(
            '=== [DeleteCheckoutArtifacts] no files found for asset $assetId');
        return;
      }

      final idsToDelete = <int>[];

      for (final f in rawFiles) {
        if (f is! Map) continue;

        final noteRaw = (f['note'] ?? f['notes'])?.toString() ?? '';
        final noteDecoded = HtmlEntityUtils.decode(noteRaw);
        final name = (f['filename'] ?? f['file_name'] ?? f['name'] ?? '')
            .toString()
            .toLowerCase();

        // Checkout signature PNG: our JSON note marker.
        var isCheckoutSignature = false;
        try {
          final meta = jsonDecode(noteDecoded) as Map<String, dynamic>;
          if (meta.containsKey('assigneeName')) {
            isCheckoutSignature = true;
          }
        } catch (_) {
          // not our JSON note
        }
        if (!isCheckoutSignature &&
            name.contains('checkout') &&
            name.contains('signature')) {
          isCheckoutSignature = true;
        }

        // Checkout PDF: plain-sentence note written by uploadPdf().
        // Explicitly excludes "checkin" filenames so a checkin PDF whose
        // sanitized name happens to also contain "checkout" as a substring
        // (it shouldn't, but be defensive) is never swept up here.
        final isCheckoutPdf = noteDecoded
                .trim()
                .toLowerCase()
                .startsWith('checkout document signed by') ||
            (name.contains('checkout') &&
                name.endsWith('.pdf') &&
                !name.contains('checkin'));

        if (isCheckoutSignature || isCheckoutPdf) {
          final fId = f['id'];
          if (fId is num) idsToDelete.add(fId.toInt());
        }
      }

      if (idsToDelete.isEmpty) {
        debugPrint('=== [DeleteCheckoutArtifacts] nothing to delete for '
            'asset $assetId');
        return;
      }

      for (final fileId in idsToDelete) {
        await _deleteFile(creds.baseUrl, headers, assetId, fileId);
      }
    } catch (e, st) {
      debugPrint('=== [DeleteCheckoutArtifacts] error: $e\n$st');
    }
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  /// Extracts the `rows` list from Snipe-IT's file-listing response,
  /// trying the confirmed `payload.rows` shape first, then a couple of
  /// fallbacks for version differences. Returns null if nothing usable.
  List<dynamic>? _extractFileRows(String responseBody) {
    final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final rawFiles = (decoded['payload'] is Map
            ? (decoded['payload'] as Map)['rows']
            : null) ??
        decoded['rows'] ??
        decoded['uploads'] ??
        decoded['files'];
    if (rawFiles is! List || rawFiles.isEmpty) return null;
    return rawFiles;
  }

  /// Finds the checkout-signature marker file among [rawFiles]. If several
  /// matches exist (from multiple past checkouts), returns the most
  /// recently uploaded one (highest file id).
  Map<String, dynamic>? _findCheckoutSignatureFile(List<dynamic> rawFiles) {
    Map<String, dynamic>? match;
    for (final f in rawFiles) {
      if (f is! Map) continue;

      bool isOurs = false;

      final noteValue = (f['note'] ?? f['notes'])?.toString();
      if (noteValue != null && noteValue.isNotEmpty) {
        try {
          final meta = jsonDecode(HtmlEntityUtils.decode(noteValue))
              as Map<String, dynamic>;
          if (meta.containsKey('assigneeName')) {
            isOurs = true;
          }
        } catch (_) {
          // Not our JSON note (e.g. the main PDF's "X document signed by
          // Y" sentence, or a manually edited note) — not a match.
        }
      }

      if (!isOurs) {
        final name = (f['filename'] ?? f['file_name'] ?? f['name'] ?? '')
            .toString()
            .toLowerCase();
        if (name.contains('checkout') && name.contains('signature')) {
          isOurs = true;
        }
      }

      if (isOurs) {
        final fId = (f['id'] as num?) ?? 0;
        final matchId = (match?['id'] as num?) ?? -1;
        if (match == null || fId > matchId) {
          match = Map<String, dynamic>.from(f);
        }
      }
    }
    return match;
  }

  // ── Delete a single hardware file, trying known route variants ───────────
  //
  // Snipe-IT's delete-file API route has changed shape across versions —
  // some expose `DELETE /hardware/{id}/files/{file_id}`, others
  // `DELETE /hardware/{id}/files/{file_id}/delete`, and some only accept a
  // POST with Laravel's `_method=DELETE` spoofing field. Rather than
  // hardcode one guess, this tries each known variant in turn and stops at
  // the first one that isn't rejected as wrong-method/not-found.
  Future<void> _deleteFile(
    String baseUrl,
    Map<String, String> headers,
    int assetId,
    int fileId,
  ) async {
    final attempts = <Future<http.Response> Function()>[
      // 1) DELETE .../files/{id}/delete
      () => http.delete(
          Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId/delete'),
          headers: headers),
      // 2) DELETE .../files/{id}  (no /delete suffix)
      () => http.delete(
          Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId'),
          headers: headers),
      // 3) POST .../files/{id}/delete  with Laravel's _method=DELETE
      //    spoofing field, for installs where the route only accepts POST.
      () => http.post(
          Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId/delete'),
          headers: headers,
          body: {'_method': 'DELETE'}),
      // 4) POST .../files/{id}  with the same spoofing field, in case the
      //    "/delete" suffix isn't part of this install's route at all.
      () => http.post(
          Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId'),
          headers: headers,
          body: {'_method': 'DELETE'}),
    ];

    for (var i = 0; i < attempts.length; i++) {
      try {
        final resp = await attempts[i]();
        debugPrint('=== [DeleteCheckoutArtifacts] file $fileId attempt '
            '${i + 1}/${attempts.length}: HTTP ${resp.statusCode} '
            '${resp.body}');

        // 405/404 mean this route shape doesn't exist here — try the next
        // variant. Anything else (200 with status success, or a real
        // permission/validation error) is a definitive result — stop.
        if (resp.statusCode == 405 || resp.statusCode == 404) {
          continue;
        }

        if (resp.statusCode == 200) {
          try {
            final body = jsonDecode(resp.body) as Map<String, dynamic>;
            if (body['status']?.toString().toLowerCase() == 'error') {
              debugPrint('=== [DeleteCheckoutArtifacts] file $fileId '
                  'rejected by server: ${body['messages']}');
            } else {
              debugPrint('=== [DeleteCheckoutArtifacts] file $fileId deleted '
                  '(variant ${i + 1})');
            }
          } catch (_) {
            // Non-JSON 200 body — treat as success and stop trying.
          }
        }
        return;
      } catch (e, st) {
        debugPrint('=== [DeleteCheckoutArtifacts] file $fileId attempt '
            '${i + 1} threw: $e\n$st');
      }
    }

    debugPrint('=== [DeleteCheckoutArtifacts] file $fileId: all delete '
        'route variants failed (405/404) — check `php artisan route:list '
        '--path=files` on the server to find the correct route for this '
        'install.');
  }
}
