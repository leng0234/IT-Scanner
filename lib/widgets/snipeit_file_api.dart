import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../../models/asset_model.dart';
import 'html_entity_utils.dart';
import 'signature_history_entry.dart';

/// All HTTP calls against Snipe-IT's `/hardware/{id}/files` endpoints:
/// uploading the signed PDF, and rebuilding the checkout/checkin history
/// for an asset.
///
/// No per-signature PNG files are stored. Instead, the checkout/checkin
/// history — including every signature image, base64-encoded — is
/// embedded as JSON in the `notes` field of a PDF file. Because Snipe-IT's
/// `notes` field has a practical size limit, history is capped to a fixed
/// number of cycles per PDF (see `maxHistoryCycles` in the dialog widget):
/// once that cap is hit, the current PDF (with its full history) is left
/// untouched forever as an archive, and a brand new PDF starts a fresh
/// history containing only the newest signing event. Over time this
/// produces a series of archived PDFs on the asset, each capturing one
/// chunk of its history, instead of one ever-growing file.
///
/// [fetchSignatureHistory] always reads from the single *newest* PDF that
/// carries our JSON marker — that's the currently "active" one still being
/// added to. Older, capped-off PDFs are never read from or written to
/// again; they just sit on the asset as a permanent record.
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

  // ── Upload the signed PDF (+ its embedded history JSON) ──────────────────
  //
  // Snipe-IT's /hardware/{id}/files endpoint can return HTTP 200 while the
  // JSON body itself says `"status": "error"` (e.g. wrong field name,
  // missing permission, bad asset id). Checking only the HTTP status code
  // would treat those in-body errors as success, so the JSON body's
  // `status` field is checked too. The multipart field name is `file[]`
  // (array form), which is what Snipe-IT's file upload endpoint expects.
  //
  // [historyEntries] must be exactly what this PDF's printed table shows —
  // whatever this PDF's `notes` says becomes the sole source of truth the
  // next time [fetchSignatureHistory] reads from it.
  //
  // Returns the id Snipe-IT assigned to the newly-created file (and the
  // filename used) so the caller can later target this exact file — e.g.
  // to strip its note once its cycle-group is fully closed off, without
  // needing a fresh files-list lookup.
  Future<({int? fileId, String fileName})> uploadPdf({
    required Uint8List pdfBytes,
    required String action,
    required AssetModel asset,
    required String? assigneeName,
    required List<SignatureHistoryEntry> historyEntries,
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

    final fileName =
        '${asset.assetTag ?? 'Asset'}_IT Asset Request and Return Form.pdf';

    final notesJson = jsonEncode({
      'pdfHistory': true,
      'summary': '$action document signed by ${assigneeName ?? 'Unknown'}',
      'history': [for (final e in historyEntries) e.toJson()],
    });

    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_headers(creds.token));
    request.files.add(
      http.MultipartFile.fromBytes('file[]', pdfBytes, filename: fileName),
    );
    request.fields['notes'] = notesJson;

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

    // Best-effort extraction of the new file's id from
    // payload.rows[0].id — if the response shape doesn't match (e.g. a
    // Snipe-IT version difference), just return null and let the caller's
    // fallback (clearArchivedFileNote via a fresh files-list lookup) cover
    // it instead.
    int? newFileId;
    try {
      final rows = (json['payload'] as Map?)?['rows'];
      if (rows is List && rows.isNotEmpty) {
        final firstRow = rows.first;
        if (firstRow is Map && firstRow['id'] is num) {
          newFileId = (firstRow['id'] as num).toInt();
        }
      }
    } catch (_) {
      // Ignore — caller falls back to the safety-net path.
    }

    return (fileId: newFileId, fileName: fileName);
  }

  // ── Rebuild the checkout/checkin history from the active PDF ─────────────
  //
  // Steps:
  //   1. List every file attached to the asset.
  //   2. Among files whose `note` decodes to our JSON marker
  //      (`pdfHistory: true`), keep the one with the highest file id —
  //      Snipe-IT ids are assigned in increasing order, so that's the most
  //      recently uploaded PDF, i.e. the currently "active" one.
  //   3. Decode its `history` array (each entry carries its signature image
  //      as base64 already, so no extra file downloads are needed).
  //   4. Pair entries that share the same `cycleId` into one row each
  //      (a checkout and its matching checkin), oldest cycle first.
  //
  // Also returns [sourceFileId] — the file id the history was read from —
  // so the caller knows exactly which file to delete if it's about to
  // upload a replacement that continues the same history thread. Returns
  // an empty result (rather than throwing) on any failure, so a history
  // lookup problem degrades to "no history shown" instead of blocking PDF
  // generation.
  Future<({List<SignatureHistoryRow> rows, int? sourceFileId})>
      fetchSignatureHistory({required int assetId}) async {
    final creds = _credentials();
    if (creds == null) return (rows: <SignatureHistoryRow>[], sourceFileId: null);
    final headers = _headers(creds.token);

    try {
      final filesUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final filesResp = await http.get(filesUri, headers: headers);
      if (filesResp.statusCode != 200) {
        debugPrint('=== [SignatureHistory] failed to fetch files list: '
            'HTTP ${filesResp.statusCode}');
        return (rows: <SignatureHistoryRow>[], sourceFileId: null);
      }

      final rawFiles = _extractFileRows(filesResp.body);
      if (rawFiles == null) {
        debugPrint('=== [SignatureHistory] no files found for asset $assetId');
        return (rows: <SignatureHistoryRow>[], sourceFileId: null);
      }

      // Find the newest PDF whose note carries our JSON marker.
      Map<String, dynamic>? latestMeta;
      int latestId = -1;
      for (final f in rawFiles) {
        if (f is! Map) continue;
        final noteValue = (f['note'] ?? f['notes'])?.toString();
        if (noteValue == null || noteValue.isEmpty) continue;
        try {
          final meta = jsonDecode(HtmlEntityUtils.decode(noteValue))
              as Map<String, dynamic>;
          if (meta['pdfHistory'] != true) continue;
          final fId = f['id'];
          if (fId is num && fId.toInt() > latestId) {
            latestId = fId.toInt();
            latestMeta = meta;
          }
        } catch (_) {
          // Not our JSON note — ignore (manual attachments, etc.).
        }
      }

      if (latestMeta == null) {
        debugPrint('=== [SignatureHistory] no history-carrying PDF found '
            'among ${rawFiles.length} file(s)');
        return (rows: <SignatureHistoryRow>[], sourceFileId: null);
      }

      final historyList = latestMeta['history'];
      if (historyList is! List) {
        return (rows: <SignatureHistoryRow>[], sourceFileId: latestId);
      }

      final entries = <SignatureHistoryEntry>[];
      for (final e in historyList) {
        if (e is! Map) continue;
        try {
          entries.add(SignatureHistoryEntry.fromJson(
              Map<String, dynamic>.from(e)));
        } catch (_) {
          continue;
        }
      }

      // Pair checkout/checkin entries sharing the same cycleId into rows.
      // `order` preserves first-seen order of each cycleId; since cycleIds
      // are minted from millisecondsSinceEpoch (see signature_dialog.dart),
      // sorting them also sorts the rows chronologically.
      final rows = <String, SignatureHistoryRow>{};
      final order = <String>[];
      for (final entry in entries) {
        final existing = rows[entry.cycleId];
        if (existing == null) {
          rows[entry.cycleId] = SignatureHistoryRow(
            cycleId: entry.cycleId,
            checkoutEntry: entry.isCheckout ? entry : null,
            checkinEntry: entry.isCheckout ? null : entry,
          );
          order.add(entry.cycleId);
        } else {
          rows[entry.cycleId] = SignatureHistoryRow(
            cycleId: entry.cycleId,
            checkoutEntry: entry.isCheckout ? entry : existing.checkoutEntry,
            checkinEntry: entry.isCheckout ? existing.checkinEntry : entry,
          );
        }
      }

      order.sort();
      return (
        rows: [for (final id in order) rows[id]!],
        sourceFileId: latestId,
      );
    } catch (e, st) {
      debugPrint('=== [SignatureHistory] lookup failed: $e\n$st');
      return (rows: <SignatureHistoryRow>[], sourceFileId: null);
    }
  }

  /// Finds the cycleId of a checkout that hasn't been matched with a
  /// checkin yet (i.e. the asset is currently checked out to someone).
  /// Returns null if there's no open cycle — meaning a fresh checkout
  /// should mint a brand new cycleId rather than reuse one.
  Future<String?> findOpenCycleId({required int assetId}) async {
    final history = await fetchSignatureHistory(assetId: assetId);
    for (final row in history.rows.reversed) {
      if (row.checkoutEntry != null && row.checkinEntry == null) {
        return row.cycleId;
      }
    }
    return null;
  }

  // ── Delete one specific PDF file ──────────────────────────────────────────
  //
  // Used only to remove the PDF that a new upload has just superseded
  // (i.e. the previous "active" PDF whose history got merged into the new
  // one). Archived, capped-off PDFs are never passed here, so they persist
  // on the asset indefinitely.
  //
  // Deliberately best-effort: a failure here (network hiccup, missing
  // delete permission, etc.) must never surface as a failed
  // checkout/checkin — it's just log-and-move-on cleanup. Worst case, an
  // old PDF is simply left behind for manual cleanup.
  Future<void> deletePdfFile({required int assetId, required int fileId}) async {
    final creds = _credentials();
    if (creds == null) {
      debugPrint('=== [DeletePdf] skipped: missing .env config');
      return;
    }
    final headers = _headers(creds.token);
    try {
      await _deleteFile(creds.baseUrl, headers, assetId, fileId);
    } catch (e, st) {
      debugPrint('=== [DeletePdf] error: $e\n$st');
    }
  }

  // ── Strip the note off a PDF whose cycle-group just closed out ───────────
  //
  // Called right after uploading a PDF that: (a) has just reached
  // `maxHistoryCycles` cycles, and (b) every one of those cycles is a
  // closed checkout+checkin pair (no open checkout waiting on a checkin).
  // Once both are true, this exact file will never be written to again —
  // the very next new cycle always starts a brand new PDF — so its note
  // (the JSON history blob with every past signature image, base64
  // encoded) is safe to strip immediately rather than waiting for that
  // next PDF to appear.
  //
  // Unlike [clearArchivedFileNote], this doesn't need to download the PDF
  // back from Snipe-IT first — the caller just finished building and
  // uploading these exact [pdfBytes], so they're reused directly. That
  // saves a network round trip, at the cost of two more Snipe-IT
  // operations (delete + re-upload) tacked onto the same action.
  //
  // Deliberately best-effort, matching the other cleanup methods here: any
  // failure is logged and swallowed rather than surfaced as a failed
  // checkout/checkin. Worst case, this file simply keeps its full note
  // and [clearArchivedFileNote]'s cap-exceeded fallback catches it later.
  Future<void> finalizeClosedCycleFile({
    required int assetId,
    required int fileId,
    required Uint8List pdfBytes,
    required String fileName,
  }) async {
    final creds = _credentials();
    if (creds == null) {
      debugPrint('=== [FinalizeClosedCycle] skipped: missing .env config');
      return;
    }
    final headers = _headers(creds.token);

    try {
      await _deleteFile(creds.baseUrl, headers, assetId, fileId);

      final uploadUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final request = http.MultipartRequest('POST', uploadUri);
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes('file[]', pdfBytes, filename: fileName),
      );
      request.fields['notes'] = '';

      final streamedResponse = await request.send();
      final respStr = await streamedResponse.stream.bytesToString();
      debugPrint('=== [FinalizeClosedCycle] re-upload for file $fileId: '
          'HTTP ${streamedResponse.statusCode}: $respStr');
    } catch (e, st) {
      debugPrint('=== [FinalizeClosedCycle] error: $e\n$st');
    }
  }

  // ── Strip the embedded-history note off an archived (capped-off) PDF ─────
  //
  // Snipe-IT's file API only exposes upload (POST) and delete (DELETE) —
  // there's no "update note" endpoint for a file that's already been
  // uploaded. So the only way to clear a previously-uploaded file's `note`
  // field is: download its bytes, delete it, then re-upload the exact same
  // bytes under a fresh file id with an empty note.
  //
  // Called once a PDF has been capped off and archived (see
  // `maxHistoryCycles` in the dialog widget): its JSON history note (which
  // embeds every signature image as base64) has already been folded into
  // the new active PDF's note, so leaving it in place would just be a
  // redundant, ever-growing copy of old signature data sitting on the
  // asset forever. The PDF file itself is kept — only its note is cleared.
  //
  // Deliberately best-effort, matching `deletePdfFile`: any failure here
  // (download hiccup, missing permission, etc.) is logged and swallowed —
  // it must never surface as a failed checkout/checkin. Worst case, the
  // archived PDF simply keeps its old note.
  Future<void> clearArchivedFileNote({
    required int assetId,
    required int fileId,
  }) async {
    final creds = _credentials();
    if (creds == null) {
      debugPrint('=== [ClearNote] skipped: missing .env config');
      return;
    }
    final headers = _headers(creds.token);

    try {
      final downloadUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files/$fileId');
      final downloadResp = await http.get(downloadUri, headers: headers);
      if (downloadResp.statusCode != 200 || downloadResp.bodyBytes.isEmpty) {
        debugPrint('=== [ClearNote] failed to download file $fileId: '
            'HTTP ${downloadResp.statusCode}');
        return;
      }

      // Recover the original filename from Content-Disposition so the
      // re-uploaded copy still looks like the same document; fall back to
      // a generic name if the header is missing or unparseable.
      var fileName = 'Archived_$fileId.pdf';
      final disposition = downloadResp.headers['content-disposition'];
      if (disposition != null) {
        final match = RegExp('filename\\*?=(?:UTF-8\'\')?"?([^";]+)"?')
            .firstMatch(disposition);
        final captured = match?.group(1);
        if (captured != null && captured.isNotEmpty) {
          try {
            fileName = Uri.decodeComponent(captured);
          } catch (_) {
            fileName = captured;
          }
        }
      }

      final pdfBytes = downloadResp.bodyBytes;

      // Delete the old (noted) copy first — if this fails, bail out rather
      // than risk ending up with two copies of the archived PDF.
      await _deleteFile(creds.baseUrl, headers, assetId, fileId);

      final uploadUri =
          Uri.parse('${creds.baseUrl}/api/v1/hardware/$assetId/files');
      final request = http.MultipartRequest('POST', uploadUri);
      request.headers.addAll(headers);
      request.files.add(
        http.MultipartFile.fromBytes('file[]', pdfBytes, filename: fileName),
      );
      request.fields['notes'] = '';

      final streamedResponse = await request.send();
      final respStr = await streamedResponse.stream.bytesToString();
      debugPrint('=== [ClearNote] re-upload for old file $fileId: '
          'HTTP ${streamedResponse.statusCode}: $respStr');
    } catch (e, st) {
      debugPrint('=== [ClearNote] error: $e\n$st');
    }
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
        debugPrint('=== [DeletePdf] file $fileId attempt '
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
              debugPrint('=== [DeletePdf] file $fileId rejected by '
                  'server: ${body['messages']}');
            } else {
              debugPrint(
                  '=== [DeletePdf] file $fileId deleted (variant ${i + 1})');
            }
          } catch (_) {
            // Non-JSON 200 body — treat as success and stop trying.
          }
        }
        return;
      } catch (e, st) {
        debugPrint(
            '=== [DeletePdf] file $fileId attempt ${i + 1} threw: $e\n$st');
      }
    }

    debugPrint('=== [DeletePdf] file $fileId: all delete route variants '
        'failed (405/404) — check `php artisan route:list --path=files` on '
        'the server to find the correct route for this install.');
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
}