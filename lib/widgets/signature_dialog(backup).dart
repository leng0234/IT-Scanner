// import 'dart:typed_data';
// import 'dart:ui' as ui;
// import 'dart:convert';
// import 'dart:async';
// import 'package:http/http.dart' as http;
// import 'package:flutter_dotenv/flutter_dotenv.dart';

// import 'package:crypto/crypto.dart'; // real cryptographic hashing
// import 'package:flutter/foundation.dart' show debugPrint;
// import 'package:flutter/material.dart';
// import 'package:flutter/services.dart';
// import 'package:html_unescape/html_unescape.dart'; // replaces hand-rolled entity decoder
// import 'package:pdf/pdf.dart';
// import 'package:pdf/widgets.dart' as pw;
// import 'package:qr/qr.dart';
// import 'package:signature/signature.dart';

// import '../models/asset_model.dart';
// import '../utils/app_constants.dart';

// // Platform-specific PDF download/share implementation.
// // - Web builds resolve to pdf_downloader_web.dart (dart:html)
// // - Native (Android/iOS/desktop) builds resolve to pdf_downloader_native.dart
// //   (path_provider + share_plus)
// // - Anything else falls back to pdf_downloader_stub.dart
// //
// // Splitting this out (instead of importing dart:html / dart:io / path_provider
// // / share_plus directly in this file behind an `if (kIsWeb)` check) is required
// // because the Dart web compiler still has to be able to *resolve* every
// // import in the file, even ones guarded by a runtime kIsWeb check — and
// // dart:io simply doesn't exist on web, which broke web builds.
// //
// // NOTE: add these to pubspec.yaml if not already present:
// //   path_provider: ^2.1.0
// //   share_plus: ^9.0.0
// import 'pdf_downloader_stub.dart'
//     if (dart.library.html) 'pdf_downloader_web.dart'
//     if (dart.library.io) 'pdf_downloader_native.dart';

// // NOTE: device-type checkbox logic (NoteBook/PC/Server) reads
// // `asset.category?.name`, falling back to `asset.model?.name` if the
// // category wasn't returned by the API. Requires `AssetModel.category`
// // (see asset_model.dart) — make sure that field is present in your model.
// //
// // NOTE (custom fields used below): the "Laptop Field Set" you configured in
// // Snipe-IT exposes RAM / Storage Type / Capacity / Monitor / S/N Monitor /
// // Type / Warranty Period / Warranty Provider as custom fields, all read via
// // `getField('<exact field name>')` further down. If any of these render as
// // '—' on the PDF, double-check the field name typed here matches the label
// // in Snipe-IT's Custom Fields admin exactly (case + spacing).
// //
// // `PO Number`, `Object ID` and `IP Address` are also pulled the same way —
// // add those as custom fields too (if not already present) so they populate
// // on the printed form; otherwise they'll simply print as '—'.

// /// Snapshot of a *prior* checkout's signature/recipient info, so that when
// /// generating a check**in** PDF, the checkout box on the same page can be
// /// filled in instead of printing blank.
// ///
// /// FUTURE WIRING (not implemented yet — storage isn't built): before calling
// /// `showSignatureDialog(isCheckOut: false, ...)`, look up the saved checkout
// /// record for this asset (by asset tag/id) from storage and build one of
// /// these from it, e.g.:
// ///
// /// ```dart
// /// final saved = await storage.getCheckoutRecord(asset.id!);
// /// final prior = saved == null
// ///     ? null
// ///     : PriorCheckoutRecord(
// ///         assigneeName: saved.assigneeName,
// ///         division: saved.division,
// ///         dateStr: saved.dateStr,
// ///         sigBytes: saved.signaturePngBytes,
// ///       );
// /// ```
// ///
// /// Until that lookup exists, just pass `null` (the default) — the checkout
// /// box on the checkin PDF will print as an empty "ยังไม่มีลายเซ็น" placeholder
// /// instead of failing.
// class PriorCheckoutRecord {
//   final String assigneeName;
//   final String? division;
//   final String dateStr;
//   final Uint8List sigBytes;

//   const PriorCheckoutRecord({
//     required this.assigneeName,
//     this.division,
//     required this.dateStr,
//     required this.sigBytes,
//   });
// }

// Future<Uint8List?> showSignatureDialog({
//   required BuildContext context,
//   required String title,
//   String? subtitle,
//   AssetModel? asset,
//   String? assigneeName,
//   String? division,
//   bool isCheckOut = true,
//   // Pass this on checkin so the generated PDF shows both the checkout and
//   // checkin signature boxes on one page. Leave null for checkout, or for
//   // checkin until the storage lookup described above is wired up.
//   PriorCheckoutRecord? priorCheckout,
// }) {
//   return showDialog<Uint8List?>(
//     context: context,
//     barrierDismissible: false,
//     builder: (_) => _SignatureDialog(
//       title: title,
//       subtitle: subtitle,
//       asset: asset,
//       assigneeName: assigneeName,
//       division: division,
//       isCheckOut: isCheckOut,
//       priorCheckout: priorCheckout,
//     ),
//   );
// }

// /// Centralized layout/format constants.
// class _PdfLayoutConstants {
//   static const double canvasWidth = 600;
//   static const double canvasHeight = 300;
//   static const int qrCellSize = 6;
//   static const int qrPadding = 12;
// }

// // Document copy (company name, titles, remarks, device-type resolution)
// // now lives in AppConstants (see app_constants.dart) instead of a local
// // class here, so it's shared with the rest of the app and only needs to
// // change in one place.

// /// Font bytes are loaded once and cached at the class (static)
// /// level instead of being re-read from the asset bundle on every single
// /// checkout/checkin PDF generation.
// ///
// /// `ensureLoaded()` is idempotent based on whether the fonts are already
// /// populated, rather than a one-shot "attempted" flag — so if a load ever
// /// fails (e.g. transient asset-bundle hiccup), the next call will retry
// /// instead of being permanently stuck on `null` fonts for the rest of the
// /// app's lifetime.
// class _FontCache {
//   static pw.Font? sarabunRegular;
//   static pw.Font? sarabunBold;

//   static Future<void> ensureLoaded() async {
//     if (sarabunRegular != null && sarabunBold != null) {
//       return;
//     }

//     sarabunRegular = await _load('assets/fonts/Sarabun-Regular.ttf');
//     sarabunBold = await _load('assets/fonts/Sarabun-Bold.ttf');
//   }

//   static Future<pw.Font?> _load(String assetPath) async {
//     try {
//       final data = await rootBundle.load(assetPath);
//       return pw.Font.ttf(data);
//     } catch (e, st) {
//       debugPrint('=== [FontCache] Failed to load $assetPath: $e\n$st');
//       return null;
//     }
//   }
// }

// /// Real SHA-256 based document verification, computed over the
// /// *entire* signature image (not just the first 32 bytes, which are mostly
// /// constant PNG header bytes and don't meaningfully distinguish signatures).
// ///
// /// The verification code is derived only from the asset tag, recipient
// /// name, date, action, and signature image hash — deliberately with no
// /// random nonce — so the exact same inputs always regenerate the exact same
// /// code and the document can be independently re-verified later, rather than
// /// only being checkable at generation time.
// class _DocumentVerification {
//   static String sha256Hex(String input) {
//     return sha256.convert(utf8.encode(input)).toString();
//   }

//   static String sha256HexBytes(Uint8List bytes) {
//     return sha256.convert(bytes).toString();
//   }

//   static String generateVerificationCode({
//     required String assetTag,
//     required String assigneeName,
//     required String dateStr,
//     required String action,
//     required Uint8List sigBytes,
//   }) {
//     final sigFingerprint = sha256HexBytes(sigBytes);
//     final payload = '$assetTag|$assigneeName|$dateStr|$action|$sigFingerprint';
//     final hash = sha256Hex(payload);
//     // Take a readable slice of the full hash for display purposes; the
//     // full hash above is still cryptographically derived from all inputs,
//     // unlike the previous FNV-1a implementation which was trivially
//     // collidable.
//     final code = hash.substring(0, 16).toUpperCase();
//     return '${code.substring(0, 4)}-${code.substring(4, 8)}-'
//         '${code.substring(8, 12)}-${code.substring(12, 16)}';
//   }
// }

// class _SignatureDialog extends StatefulWidget {
//   final String title;
//   final String? subtitle;
//   final AssetModel? asset;
//   final String? assigneeName;
//   final String? division;
//   final bool isCheckOut;
//   final PriorCheckoutRecord? priorCheckout;

//   const _SignatureDialog({
//     required this.title,
//     this.subtitle,
//     this.asset,
//     this.assigneeName,
//     this.division,
//     this.isCheckOut = true,
//     this.priorCheckout,
//   });

//   @override
//   State<_SignatureDialog> createState() => _SignatureDialogState();
// }

// /// Standalone typedef for avoiding inline nesting issues on some Dart analyzers.
// typedef _PdfTextStyleBuilder = pw.TextStyle Function({
//   double size,
//   pw.Font? font,
//   PdfColor color,
//   double? lineSpacing,
// });

// class _SignatureDialogState extends State<_SignatureDialog> {
//   late final SignatureController _controller;
//   bool _isEmpty = true;
//   bool _isExporting = false;
//   String? _exportError;

//   @override
//   void initState() {
//     super.initState();
//     _controller = SignatureController(
//       penStrokeWidth: 3.5,
//       penColor: AppConstants.primaryNavy,
//       exportBackgroundColor: Colors.white,
//     )..addListener(() {
//         setState(() => _isEmpty = _controller.isEmpty);
//       });
//     // Warm the font cache as soon as the dialog opens so the PDF
//     // generation step later doesn't pay the asset-load cost.
//     unawaited(_FontCache.ensureLoaded());
//   }

//   @override
//   void dispose() {
//     _controller.dispose();
//     super.dispose();
//   }

//   // ── HTML entity decoder ────────────────────────────────────────────────────
//   static final HtmlUnescape _htmlUnescape = HtmlUnescape();

//   String _decodeHtmlEntities(String input) => _htmlUnescape.convert(input);

//   // ── Export signature PNG ───────────────────────────────────────────────────

//   Future<Uint8List?> _exportSignatureBytes() async {
//     Uint8List? pngBytes;

//     try {
//       // FIX: ถอดการล็อกขนาดกว้างคูณสูงตายตัวออก เพื่อดึงค่าพิกัดความละเอียดจริงตามหน้าจอ (Natural Size) ลายเซ็นจะไม่โดนตัดขอบขวาอีกต่อไป
//       pngBytes = await _controller.toPngBytes();
//     } catch (e, st) {
//       debugPrint('=== [Signature] toPngBytes failed: $e\n$st');
//     }

//     if (pngBytes == null || pngBytes.isEmpty) {
//       try {
//         final image = await _controller.toImage();
//         if (image != null) {
//           final byteData =
//               await image.toByteData(format: ui.ImageByteFormat.png);
//           pngBytes = byteData?.buffer.asUint8List();
//         }
//       } catch (e, st) {
//         debugPrint('=== [Signature] toImage fallback failed: $e\n$st');
//       }
//     }

//     if (pngBytes == null || pngBytes.isEmpty) {
//       // FIX: ปรับ Manual Canvas Fallback ให้คำนวณพื้นที่ความกว้างลึกจริงจากจุดพิกัดการลากเส้น เพื่อไม่ให้สัดส่วนบีบอัดจนขาดตอน
//       try {
//         double maxX = 0;
//         double maxY = 0;
//         for (final point in _controller.points) {
//           if (point != null) {
//             if (point.offset.dx > maxX) maxX = point.offset.dx;
//             if (point.offset.dy > maxY) maxY = point.offset.dy;
//           }
//         }

//         final w = (maxX + 20).clamp(300.0, 2000.0);
//         final h = (maxY + 20).clamp(220.0, 2000.0);

//         final recorder = ui.PictureRecorder();
//         final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
//         canvas.drawRect(
//             Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
//         final paint = Paint()
//           ..color = AppConstants.primaryNavy
//           ..strokeWidth = 3.5
//           ..strokeCap = StrokeCap.round
//           ..strokeJoin = StrokeJoin.round
//           ..style = PaintingStyle.stroke;

//         Offset? previous;
//         for (final point in _controller.points) {
//           if (point == null) {
//             previous = null;
//             continue;
//           }
//           if (previous != null) {
//             canvas.drawLine(previous, point.offset, paint);
//           } else {
//             canvas.drawCircle(
//               point.offset,
//               1.75,
//               Paint()..color = AppConstants.primaryNavy,
//             );
//           }
//           previous = point.offset;
//         }

//         final picture = recorder.endRecording();
//         final img = await picture.toImage(w.toInt(), h.toInt());
//         final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
//         pngBytes = byteData?.buffer.asUint8List();
//       } catch (e, st) {
//         debugPrint('=== [Signature] manual canvas fallback failed: $e\n$st');
//       }
//     }

//     return pngBytes;
//   }

//   // ── QR PNG via dart:ui canvas ──────────────────────────────────────────────

//   Future<Uint8List> _generateQrPngBytes(String data) async {
//     final qr = QrCode.fromData(
//       data: data,
//       errorCorrectLevel: QrErrorCorrectLevel.M,
//     );
//     final qrImage = QrImage(qr);
//     final moduleCount = qr.moduleCount;
//     const cellSize = _PdfLayoutConstants.qrCellSize;
//     const padding = _PdfLayoutConstants.qrPadding;
//     final totalSize = moduleCount * cellSize + padding * 2;

//     final recorder = ui.PictureRecorder();
//     final canvas = Canvas(
//       recorder,
//       Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
//     );
//     canvas.drawRect(
//       Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
//       Paint()..color = Colors.white,
//     );
//     final paint = Paint()..color = Colors.black;
//     for (var row = 0; row < moduleCount; row++) {
//       for (var col = 0; col < moduleCount; col++) {
//         if (qrImage.isDark(row, col)) {
//           canvas.drawRect(
//             Rect.fromLTWH(
//               (col * cellSize + padding).toDouble(),
//               (row * cellSize + padding).toDouble(),
//               cellSize.toDouble(),
//               cellSize.toDouble(),
//             ),
//             paint,
//           );
//         }
//       }
//     }
//     final picture = recorder.endRecording();
//     final img = await picture.toImage(totalSize, totalSize);
//     final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
//     return byteData!.buffer.asUint8List();
//   }

//   // ── Confirm ────────────────────────────────────────────────────────────────

//   Future<void> _confirm() async {
//     if (_controller.isEmpty) return;
//     setState(() {
//       _isExporting = true;
//       _exportError = null;
//     });

//     try {
//       final pngBytes = await _exportSignatureBytes();

//       if (pngBytes == null || pngBytes.isEmpty) {
//         if (mounted) {
//           setState(() {
//             _isExporting = false;
//             _exportError = 'Cannot save signature. Please try again.';
//           });
//         }
//         return;
//       }

//       if (widget.asset != null) {
//         await _generateAndDownloadPdf(pngBytes);
//       }

//       if (mounted) Navigator.of(context).pop(pngBytes);
//     } catch (e, st) {
//       debugPrint('=== [Signature] _confirm failed: $e\n$st');
//       if (mounted) {
//         setState(() {
//           _isExporting = false;
//           _exportError = 'Error: $e';
//         });
//       }
//     }
//   }

//   // ── Generate & download PDF ────────────────────────────────────────────────
//   // ── Upload PDF to Snipe-IT ────────────────────────────────────────────────
//   //
//   // FIX (env keys): previously this read `dotenv.env['http://192.168.89.10']`
//   // and `dotenv.env['eyJ...<jwt>...']` — i.e. it used the *actual values* as
//   // the lookup *keys*, which can never match anything in a real .env file
//   // (whose keys are names like SNIPEIT_BASE_URL=...). That made both lookups
//   // return null every time, so the upload always failed before a single
//   // HTTP request was even sent. Now it reads by proper key name.
//   //
//   // FIX (silent-fail upload): Snipe-IT's /hardware/{id}/files endpoint can
//   // return HTTP 200 while the JSON body itself says `"status": "error"`
//   // (e.g. wrong field name, missing permission, bad asset id). The old code
//   // only checked `response.statusCode != 200`, so those in-body errors were
//   // treated as success and the app reported "uploaded" while Snipe-IT never
//   // actually stored a file. Now the JSON body's `status` field is checked
//   // too, and the multipart field name uses `file[]` (array form), which is
//   // what Snipe-IT's file upload endpoint expects.
//   Future<void> _uploadPdfToSnipeIT(
//       Uint8List pdfBytes, String action, AssetModel asset) async {
//     final assetId = asset.id;
//     if (assetId == null) {
//       throw Exception('Asset ID is missing. Cannot upload to Snipe-IT.');
//     }

//     // ดึงค่า URL และ Token จาก .env โดยอ้างอิงด้วย "ชื่อคีย์"
//     // ตั้งค่าใน .env ของโปรเจกต์ดังนี้:
//     //   SNIPEIT_BASE_URL=http://192.168.89.10
//     //   SNIPEIT_API_TOKEN=eyJ...(JWT token จาก Snipe-IT)
//     final baseUrl = dotenv.env['SNIPEIT_BASE_URL'];
//     final token = dotenv.env['SNIPEIT_API_TOKEN'];

//     if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
//       throw Exception('Snipe-IT URL or Token not found in .env '
//           '(check keys SNIPEIT_BASE_URL / SNIPEIT_API_TOKEN)');
//     }

//     // สร้าง URL สำหรับ Endpoint Upload
//     final uri = Uri.parse('$baseUrl/api/v1/hardware/$assetId/files');

//     // ตั้งชื่อไฟล์
//     final now = DateTime.now();
//     final dateString =
//         '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
//     final fileName =
//         '${asset.assetTag ?? 'Asset'}_${widget.assigneeName ?? 'User'}_${dateString}_$action.pdf';

//     // สร้าง MultipartRequest
//     final request = http.MultipartRequest('POST', uri);
//     request.headers.addAll({
//       'Accept': 'application/json',
//       'Authorization': 'Bearer $token',
//     });

//     // แนบไฟล์ PDF — Snipe-IT API ใช้ field ชื่อ 'file[]' (array form)
//     request.files.add(
//       http.MultipartFile.fromBytes(
//         'file[]',
//         pdfBytes,
//         filename: fileName,
//       ),
//     );

//     // ใส่ Note แจ้งรายละเอียด (Optional)
//     request.fields['notes'] =
//         '$action document signed by ${widget.assigneeName ?? 'Unknown'}';

//     final streamedResponse = await request.send();
//     final respStr = await streamedResponse.stream.bytesToString();

//     debugPrint('=== [Upload] HTTP ${streamedResponse.statusCode}: $respStr');

//     // 1) ตรวจ HTTP status code ก่อน
//     if (streamedResponse.statusCode != 200) {
//       throw Exception(
//           'Failed to upload: HTTP ${streamedResponse.statusCode} - $respStr');
//     }

//     // 2) Snipe-IT อาจตอบ HTTP 200 พร้อม body ที่บอกว่า error จริง ๆ
//     //    (เช่น field ผิด / ไม่มีสิทธิ์ / asset id ไม่ถูกต้อง) ต้องเช็ค
//     //    "status" ใน JSON body ด้วย ไม่งั้นแอปจะรายงานว่าสำเร็จทั้งที่
//     //    ไม่มีไฟล์ถูกบันทึกจริงใน Snipe-IT
//     Map<String, dynamic> json;
//     try {
//       json = jsonDecode(respStr) as Map<String, dynamic>;
//     } catch (e) {
//       throw Exception('Unexpected response from Snipe-IT: $respStr');
//     }

//     final status = json['status']?.toString().toLowerCase();
//     if (status == 'error') {
//       final messages = json['messages'];
//       throw Exception('Snipe-IT rejected the upload: $messages');
//     }

//     debugPrint('=== [Upload] Success: PDF uploaded for Asset ID $assetId');
//   }

//   // ── Save checkout signature separately (for later reuse on checkin) ──────
//   //
//   // NEW FEATURE: when checking a device OUT, we additionally upload just the
//   // signature PNG (not the whole PDF) as its own small file attached to the
//   // asset, tagged with a recognizable filename marker
//   // (`_checkout_signature_<assetId>.png`) and with the recipient's
//   // name/division/date packed as JSON into that file's `notes` field.
//   //
//   // Later, when the SAME asset is checked back IN, `_fetchPriorCheckoutRecord`
//   // looks this file up and downloads it, so the "Receive" box on the checkin
//   // PDF is filled in automatically with the original checkout signature
//   // instead of printing "ยังไม่มีลายเซ็น" — no local storage needed, Snipe-IT
//   // itself is the storage.
//   //
//   // This is deliberately best-effort: if it fails, we only log it and move
//   // on, since a failure here must never block the checkout flow the user is
//   // actually waiting on.
//   //
//   // NOTE: this is now `await`-ed by the caller (see _generateAndDownloadPdf)
//   // instead of being fired-and-forgotten with `unawaited`. If the checkin
//   // flow can be started within a second or two of checkout completing, an
//   // un-awaited upload could still be in flight when
//   // _fetchPriorCheckoutRecord runs, making it look "missing" even though it
//   // would have succeeded a moment later.
//   Future<void> _uploadCheckoutSignatureToSnipeIT(
//     Uint8List sigBytes,
//     AssetModel asset,
//     String dateStr,
//   ) async {
//     final assetId = asset.id;
//     if (assetId == null) return;

//     final baseUrl = dotenv.env['SNIPEIT_BASE_URL'];
//     final token = dotenv.env['SNIPEIT_API_TOKEN'];
//     if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
//       debugPrint('=== [CheckoutSignature Upload] skipped: missing .env config');
//       return;
//     }

//     try {
//       final uri = Uri.parse('$baseUrl/api/v1/hardware/$assetId/files');
//       final fileName = '_checkout_signature_$assetId.png';

//       final metaNotes = jsonEncode({
//         'assigneeName': widget.assigneeName ?? '—',
//         'division': widget.division,
//         'dateStr': dateStr,
//       });

//       final request = http.MultipartRequest('POST', uri);
//       request.headers.addAll({
//         'Accept': 'application/json',
//         'Authorization': 'Bearer $token',
//       });
//       request.files.add(
//         http.MultipartFile.fromBytes('file[]', sigBytes, filename: fileName),
//       );
//       request.fields['notes'] = metaNotes;

//       final streamed = await request.send();
//       final body = await streamed.stream.bytesToString();
//       debugPrint(
//           '=== [CheckoutSignature Upload] HTTP ${streamed.statusCode}: $body');
//     } catch (e, st) {
//       debugPrint('=== [CheckoutSignature Upload] error: $e\n$st');
//     }
//   }

//   // ── Look up the checkout signature saved above (for checkin PDFs) ────────
//   //
//   // CONFIRMED RESPONSE SHAPE (from live debug log on 2026-07-03): Snipe-IT's
//   // file-listing calls (both the upload response and — per Snipe-IT's API
//   // convention of reusing the same list wrapper — the dedicated files list
//   // endpoint) return:
//   //   { "status": "success", "payload": { "total": N, "rows": [ {
//   //       "id": 66, "filename": "...", "note": "...", ...
//   //   } ] } }
//   // Two things differ from a first guess: the files live under
//   // `GET /hardware/{id}/files` (NOT embedded in the plain asset-detail
//   // response), and the per-file note key is `note` (singular), not `notes`.
//   // Both are handled below; a couple of alternate shapes are still checked
//   // as a fallback in case of version differences, so this degrades to
//   // returning null (blank checkout box, same as before) instead of crashing
//   // if your instance differs further.
//   //
//   // FIX (matching logic): confirmed via live log on 2026-07-03 that
//   // Snipe-IT renames every uploaded file on its own — it prefixes
//   // "asset-{id}-{randomhash}-" and converts underscores to hyphens (e.g.
//   // our "checkin" PDF upload, sent with underscores in the filename, came
//   // back stored as "asset-8-OYTSzdEk-...-checkin.pdf"). That means the
//   // checkout-signature file, uploaded as "_checkout_signature_{id}.png",
//   // does NOT keep that exact substring once Snipe-IT stores it — matching
//   // on `.contains('_checkout_signature_')` therefore always failed, even
//   // though the file had uploaded successfully. Matching is now done
//   // primarily via the `note` JSON payload (which we control and Snipe-IT
//   // does not rewrite), with a looser, separator-agnostic filename check as
//   // a fallback.
//   // ── Delete a single hardware file, trying known route variants ───────────
//   //
//   // Snipe-IT's delete-file API route has changed shape across versions —
//   // some expose `DELETE /hardware/{id}/files/{file_id}`, others
//   // `DELETE /hardware/{id}/files/{file_id}/delete`, and some only accept a
//   // POST with Laravel's `_method=DELETE` spoofing field. Both plain DELETE
//   // variants returned HTTP 405 on this install (confirmed via live log on
//   // 2026-07-03), so rather than hardcode one guess, this tries each known
//   // variant in turn and stops at the first one that isn't rejected as
//   // wrong-method/not-found. Logs every attempt so the working variant (or
//   // the fact that none worked) is visible in debug output.
//   Future<void> _deleteSnipeItFile(
//     String baseUrl,
//     Map<String, String> headers,
//     int assetId,
//     int fileId,
//   ) async {
//     final attempts = <Future<http.Response> Function()>[
//       // 1) DELETE .../files/{id}/delete
//       () => http.delete(
//           Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId/delete'),
//           headers: headers),
//       // 2) DELETE .../files/{id}  (no /delete suffix)
//       () => http.delete(
//           Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId'),
//           headers: headers),
//       // 3) POST .../files/{id}/delete  with Laravel's _method=DELETE
//       //    spoofing field, for installs where the route only accepts POST.
//       () => http.post(
//           Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId/delete'),
//           headers: headers,
//           body: {'_method': 'DELETE'}),
//       // 4) POST .../files/{id}  with the same spoofing field, in case the
//       //    "/delete" suffix isn't part of this install's route at all.
//       () => http.post(
//           Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId'),
//           headers: headers,
//           body: {'_method': 'DELETE'}),
//     ];

//     for (var i = 0; i < attempts.length; i++) {
//       try {
//         final resp = await attempts[i]();
//         debugPrint('=== [DeleteCheckoutArtifacts] file $fileId attempt '
//             '${i + 1}/${attempts.length}: HTTP ${resp.statusCode} '
//             '${resp.body}');

//         // 405/404 mean this route shape doesn't exist here — try the next
//         // variant. Anything else (200 with status success, or a real
//         // permission/validation error) is a definitive result — stop.
//         if (resp.statusCode == 405 || resp.statusCode == 404) {
//           continue;
//         }

//         if (resp.statusCode == 200) {
//           try {
//             final body = jsonDecode(resp.body) as Map<String, dynamic>;
//             if (body['status']?.toString().toLowerCase() == 'error') {
//               debugPrint('=== [DeleteCheckoutArtifacts] file $fileId '
//                   'rejected by server: ${body['messages']}');
//             } else {
//               debugPrint('=== [DeleteCheckoutArtifacts] file $fileId deleted '
//                   '(variant ${i + 1})');
//             }
//           } catch (_) {
//             // Non-JSON 200 body — treat as success and stop trying.
//           }
//         }
//         return;
//       } catch (e, st) {
//         debugPrint('=== [DeleteCheckoutArtifacts] file $fileId attempt '
//             '${i + 1} threw: $e\n$st');
//       }
//     }

//     debugPrint('=== [DeleteCheckoutArtifacts] file $fileId: all delete '
//         'route variants failed (405/404) — check `php artisan route:list '
//         '--path=files` on the server to find the correct route for this '
//         'install.');
//   }

//   Future<PriorCheckoutRecord?> _fetchPriorCheckoutRecord(int assetId) async {
//     final baseUrl = dotenv.env['SNIPEIT_BASE_URL'];
//     final token = dotenv.env['SNIPEIT_API_TOKEN'];
//     if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
//       return null;
//     }

//     final headers = {
//       'Accept': 'application/json',
//       'Authorization': 'Bearer $token',
//     };

//     try {
//       // 1) List files attached to this asset via the dedicated files
//       //    endpoint (this is what actually holds them — the plain asset
//       //    detail endpoint does not).
//       final filesUri = Uri.parse('$baseUrl/api/v1/hardware/$assetId/files');
//       final filesResp = await http.get(filesUri, headers: headers);
//       if (filesResp.statusCode != 200) {
//         debugPrint('=== [PriorCheckout] failed to fetch files list: '
//             'HTTP ${filesResp.statusCode}');
//         return null;
//       }

//       final filesJson = jsonDecode(filesResp.body) as Map<String, dynamic>;
//       // Try the confirmed shape first (payload.rows), then a couple of
//       // fallbacks in case of version differences.
//       final rawFiles = (filesJson['payload'] is Map
//               ? (filesJson['payload'] as Map)['rows']
//               : null) ??
//           filesJson['rows'] ??
//           filesJson['uploads'] ??
//           filesJson['files'];
//       if (rawFiles is! List || rawFiles.isEmpty) {
//         debugPrint('=== [PriorCheckout] no files found in response: '
//             '${filesResp.body}');
//         return null;
//       }

//       // 2) Find our checkout-signature marker file.
//       //
//       //    Primary match: the `note` field, which is a JSON blob we wrote
//       //    ourselves in _uploadCheckoutSignatureToSnipeIT (it contains an
//       //    `assigneeName` key). Snipe-IT stores notes verbatim, unlike
//       //    filenames, so this survives intact and is the reliable signal.
//       //
//       //    Fallback match: filename contains both "checkout" and
//       //    "signature" (case-insensitive), regardless of whether Snipe-IT
//       //    rewrote separators as underscores or hyphens.
//       //
//       //    If several matches exist (from multiple past checkouts), take
//       //    the most recently uploaded one (highest file id).
//       Map<String, dynamic>? match;
//       for (final f in rawFiles) {
//         if (f is! Map) continue;

//         bool isOurs = false;

//         final noteValue = (f['note'] ?? f['notes'])?.toString();
//         if (noteValue != null && noteValue.isNotEmpty) {
//           try {
//             // FIX: Snipe-IT HTML-encodes stored note text (e.g. `"`
//             // becomes `&quot;`), same as it does for custom field values
//             // elsewhere in this file. jsonDecode on the raw, still-encoded
//             // string throws (the payload looks like
//             // `{&quot;assigneeName&quot;:...}`, not valid JSON), so this
//             // match — and, more importantly, the field extraction in step
//             // 4 below — silently failed and fell back to defaults. Decode
//             // entities first so the JSON is well-formed again.
//             final meta = jsonDecode(_decodeHtmlEntities(noteValue))
//                 as Map<String, dynamic>;
//             if (meta.containsKey('assigneeName')) {
//               isOurs = true;
//             }
//           } catch (_) {
//             // Not our JSON note (e.g. the main PDF's "X document signed by
//             // Y" sentence, or a manually edited note) — not a match.
//           }
//         }

//         if (!isOurs) {
//           final name = (f['filename'] ?? f['file_name'] ?? f['name'] ?? '')
//               .toString()
//               .toLowerCase();
//           if (name.contains('checkout') && name.contains('signature')) {
//             isOurs = true;
//           }
//         }

//         if (isOurs) {
//           final fId = (f['id'] as num?) ?? 0;
//           final matchId = (match?['id'] as num?) ?? -1;
//           if (match == null || fId > matchId) {
//             match = Map<String, dynamic>.from(f);
//           }
//         }
//       }

//       if (match == null) {
//         debugPrint('=== [PriorCheckout] no checkout-signature file found '
//             'among ${rawFiles.length} file(s)');
//         return null;
//       }

//       final fileId = match['id'];
//       if (fileId == null) return null;

//       // 3) Download the actual PNG bytes.
//       final fileUri =
//           Uri.parse('$baseUrl/api/v1/hardware/$assetId/files/$fileId');
//       final fileResp = await http.get(fileUri, headers: headers);
//       if (fileResp.statusCode != 200 || fileResp.bodyBytes.isEmpty) {
//         debugPrint('=== [PriorCheckout] failed to download file $fileId: '
//             'HTTP ${fileResp.statusCode}');
//         return null;
//       }

//       // 4) Recover assignee/division/date, packed as JSON into the file's
//       //    note when it was uploaded (see _uploadCheckoutSignatureToSnipeIT
//       //    above). Snipe-IT returns this back as `note` (singular) even
//       //    though the upload field is named `notes` — check both.
//       String? assigneeName;
//       String? division;
//       String? dateStr;
//       final noteValue = (match['note'] ?? match['notes'])?.toString();
//       if (noteValue != null && noteValue.isNotEmpty) {
//         try {
//           // FIX: decode HTML entities before parsing — see the matching
//           // comment in the isOurs check above. This is the fix that
//           // actually restores the checkout date on the checkin PDF: this
//           // extraction step is what populates `dateStr`, and it has no
//           // fallback other than the literal '—', unlike assigneeName /
//           // division which happen to fall back to the checkin person's own
//           // values (often the same person, masking the bug there).
//           final meta = jsonDecode(_decodeHtmlEntities(noteValue))
//               as Map<String, dynamic>;
//           assigneeName = meta['assigneeName']?.toString();
//           division = meta['division']?.toString();
//           dateStr = meta['dateStr']?.toString();
//         } catch (_) {
//           // note wasn't our JSON payload (e.g. edited manually) — ignore.
//         }
//       }

//       return PriorCheckoutRecord(
//         assigneeName: assigneeName ?? widget.assigneeName ?? '—',
//         division: division ?? widget.division,
//         dateStr: dateStr ?? '—',
//         sigBytes: fileResp.bodyBytes,
//       );
//     } catch (e, st) {
//       debugPrint('=== [PriorCheckout] lookup failed: $e\n$st');
//       return null;
//     }
//   }

//   // ── Clean up checkout artifacts once checked back in ──────────────────────
//   //
//   // NEW FEATURE: after a successful CHECKIN, delete the two files that were
//   // uploaded during the matching CHECKOUT — the checkout PDF (see
//   // _uploadPdfToSnipeIT) and the standalone checkout-signature PNG (see
//   // _uploadCheckoutSignatureToSnipeIT) — so Snipe-IT ends up holding just
//   // this one checkin PDF instead of accumulating a growing pile of files
//   // (checkout PDF + signature PNG + checkin PDF) every checkout/checkin
//   // cycle.
//   //
//   // Identification mirrors _fetchPriorCheckoutRecord's matching logic:
//   //   - Checkout signature PNG: `note` decodes (after HTML-entity
//   //     unescaping — see the fix in _fetchPriorCheckoutRecord) to JSON
//   //     containing an `assigneeName` key, which only our checkout-signature
//   //     uploads ever write.
//   //   - Checkout PDF: `note` is the plain sentence written by
//   //     _uploadPdfToSnipeIT, i.e. "Checkout document signed by <name>".
//   // Both fall back to a looser, separator-agnostic filename check (Snipe-IT
//   // renames files on its own — see the note in _fetchPriorCheckoutRecord)
//   // in case the note itself is missing or was edited.
//   //
//   // Deliberately best-effort: this only runs *after* the checkin PDF has
//   // already uploaded successfully, so a failure here (network hiccup,
//   // missing delete permission, etc.) must never surface as a failed
//   // checkin — it's just log-and-move-on cleanup. Worst case, the old files
//   // are simply left behind for manual cleanup.
//   Future<void> _deleteCheckoutArtifacts(int assetId) async {
//     final baseUrl = dotenv.env['SNIPEIT_BASE_URL'];
//     final token = dotenv.env['SNIPEIT_API_TOKEN'];
//     if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
//       debugPrint('=== [DeleteCheckoutArtifacts] skipped: missing .env config');
//       return;
//     }

//     final headers = {
//       'Accept': 'application/json',
//       'Authorization': 'Bearer $token',
//     };

//     try {
//       final filesUri = Uri.parse('$baseUrl/api/v1/hardware/$assetId/files');
//       final filesResp = await http.get(filesUri, headers: headers);
//       if (filesResp.statusCode != 200) {
//         debugPrint('=== [DeleteCheckoutArtifacts] failed to fetch files '
//             'list: HTTP ${filesResp.statusCode}');
//         return;
//       }

//       final filesJson = jsonDecode(filesResp.body) as Map<String, dynamic>;
//       final rawFiles = (filesJson['payload'] is Map
//               ? (filesJson['payload'] as Map)['rows']
//               : null) ??
//           filesJson['rows'] ??
//           filesJson['uploads'] ??
//           filesJson['files'];
//       if (rawFiles is! List || rawFiles.isEmpty) {
//         debugPrint(
//             '=== [DeleteCheckoutArtifacts] no files found for asset $assetId');
//         return;
//       }

//       final idsToDelete = <int>[];

//       for (final f in rawFiles) {
//         if (f is! Map) continue;

//         final noteRaw = (f['note'] ?? f['notes'])?.toString() ?? '';
//         final noteDecoded = _decodeHtmlEntities(noteRaw);
//         final name = (f['filename'] ?? f['file_name'] ?? f['name'] ?? '')
//             .toString()
//             .toLowerCase();

//         // Checkout signature PNG: our JSON note marker.
//         var isCheckoutSignature = false;
//         try {
//           final meta = jsonDecode(noteDecoded) as Map<String, dynamic>;
//           if (meta.containsKey('assigneeName')) {
//             isCheckoutSignature = true;
//           }
//         } catch (_) {
//           // not our JSON note
//         }
//         if (!isCheckoutSignature &&
//             name.contains('checkout') &&
//             name.contains('signature')) {
//           isCheckoutSignature = true;
//         }

//         // Checkout PDF: plain-sentence note written by _uploadPdfToSnipeIT.
//         // Explicitly excludes "checkin" filenames so a checkin PDF whose
//         // sanitized name happens to also contain "checkout" as a substring
//         // (it shouldn't, but be defensive) is never swept up here.
//         final isCheckoutPdf = noteDecoded
//                 .trim()
//                 .toLowerCase()
//                 .startsWith('checkout document signed by') ||
//             (name.contains('checkout') &&
//                 name.endsWith('.pdf') &&
//                 !name.contains('checkin'));

//         if (isCheckoutSignature || isCheckoutPdf) {
//           final fId = f['id'];
//           if (fId is num) idsToDelete.add(fId.toInt());
//         }
//       }

//       if (idsToDelete.isEmpty) {
//         debugPrint('=== [DeleteCheckoutArtifacts] nothing to delete for '
//             'asset $assetId');
//         return;
//       }

//       for (final fileId in idsToDelete) {
//         await _deleteSnipeItFile(baseUrl, headers, assetId, fileId);
//       }
//     } catch (e, st) {
//       debugPrint('=== [DeleteCheckoutArtifacts] error: $e\n$st');
//     }
//   }

//   Future<void> _generateAndDownloadPdf(Uint8List sigBytes) async {
//     final now = DateTime.now();
//     final dateStr =
//         '${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

//     final asset = widget.asset!;
//     final action = widget.isCheckOut ? 'Checkout' : 'Checkin';

//     // NEW: for a checkin, if the caller didn't already pass in a
//     // PriorCheckoutRecord, try to auto-recover the checkout signature/info
//     // we saved to Snipe-IT when this asset was checked out, so the
//     // "Receive" box on this checkin PDF isn't blank.
//     PriorCheckoutRecord? priorCheckout = widget.priorCheckout;
//     if (!widget.isCheckOut && priorCheckout == null && asset.id != null) {
//       priorCheckout = await _fetchPriorCheckoutRecord(asset.id!);
//     }

//     final verifyCode = _DocumentVerification.generateVerificationCode(
//       assetTag: asset.assetTag ?? '—',
//       assigneeName: widget.assigneeName ?? '—',
//       dateStr: dateStr,
//       action: action,
//       sigBytes: sigBytes,
//     );

//     final qrData = [
//       'ASSET:${asset.assetTag ?? '—'}',
//       'ACTION:$action',
//       'RECIPIENT:${widget.assigneeName ?? '—'}',
//       'DIVISION:${widget.division ?? '—'}',
//       'DATE:$dateStr',
//       'SERIAL:${asset.serial ?? '—'}',
//       'VERIFY:$verifyCode',
//     ].join('\n');

//     final qrPngBytes = await _generateQrPngBytes(qrData);

//     await _FontCache.ensureLoaded();

//     // Logo
//     Uint8List? logoBytes;
//     try {
//       final data = await rootBundle.load('assets/stream_logoNew.png');
//       logoBytes = data.buffer.asUint8List();
//     } catch (e, st) {
//       debugPrint('=== [PDF] Failed to load logo: $e\n$st');
//     }

//     final pdfBytes = await _buildPdf(
//       action: action,
//       dateStr: dateStr,
//       asset: asset,
//       assigneeName: widget.assigneeName ?? '—',
//       division: widget.division ?? '—',
//       sigBytes: sigBytes,
//       qrPngBytes: qrPngBytes,
//       logoBytes: logoBytes,
//       verifyCode: verifyCode,
//       sarabunRegular: _FontCache.sarabunRegular,
//       sarabunBold: _FontCache.sarabunBold,
//       priorCheckout: priorCheckout,
//     );

//     // Upload PDF ไปยัง Snipe-IT
//     try {
//       await _uploadPdfToSnipeIT(
//         pdfBytes,
//         action,
//         asset,
//       );

//       debugPrint('=== [Upload PDF] success');

//       // NEW: on a successful CHECKOUT, also stash just the signature PNG so
//       // a future checkin of this same asset can pull it back automatically
//       // (see _uploadCheckoutSignatureToSnipeIT / _fetchPriorCheckoutRecord
//       // above).
//       //
//       // FIX: this is now `await`-ed instead of `unawaited`. Best-effort
//       // still applies (failures here must never block the checkout the
//       // user is waiting on, and _uploadCheckoutSignatureToSnipeIT already
//       // swallows its own errors internally) — but firing it without
//       // awaiting meant a checkin started moments later could race the
//       // upload and find nothing yet, making a successful save look like a
//       // missing signature. Awaiting costs a few hundred ms (small PNG) and
//       // removes that race entirely.
//       if (widget.isCheckOut) {
//         await _uploadCheckoutSignatureToSnipeIT(sigBytes, asset, dateStr);
//       } else if (asset.id != null) {
//         // NEW: on a successful CHECKIN, remove the checkout PDF and the
//         // standalone checkout-signature PNG from this asset — see
//         // _deleteCheckoutArtifacts above. This runs only after the checkin
//         // PDF itself uploaded successfully, and never blocks or fails the
//         // checkin if cleanup has trouble.
//         await _deleteCheckoutArtifacts(asset.id!);
//       }
//     } catch (e, st) {
//       debugPrint('=== [Upload PDF] error: $e\n$st');

//       if (mounted) {
//         setState(() {
//           _exportError = 'PDF upload failed: $e';
//         });
//       }

//       rethrow;
//     }
//   }

//   // ── Build PDF ──────────────────────────────────────────────────────────────

//   Future<Uint8List> _buildPdf({
//     required String action,
//     required String dateStr,
//     required AssetModel asset,
//     required String assigneeName,
//     required String division,
//     required Uint8List sigBytes,
//     required Uint8List qrPngBytes,
//     Uint8List? logoBytes,
//     String verifyCode = '',
//     pw.Font? sarabunRegular,
//     pw.Font? sarabunBold,
//     PriorCheckoutRecord? priorCheckout,
//   }) async {
//     String getField(String key) {
//       final field = (asset.customFields ?? {})[key];
//       if (field == null) return '—';
//       final raw = field['value']?.toString() ?? '—';
//       return _decodeHtmlEntities(raw);
//     }

//     final tag = asset.assetTag ?? '—';
//     final serial = asset.serial ?? '—';
//     final manufacturer = _decodeHtmlEntities(asset.manufacturer?.name ?? '—');
//     final model = _decodeHtmlEntities(asset.model?.name ?? '—');
//     final ram = getField('RAM');
//     final storageType = getField('Storage Type');
//     final capacity = getField('Capacity');
//     final monitor = getField('Monitor');
//     final monitorType = getField('Type');
//     final monitorSerial = getField('S/N Monitor');
//     final warrantyPeriod = getField('Warranty Period');
//     final warrantyProvider = getField('Warranty Provider');
//     final poNumber = getField('PO Number');
//     final objectId = getField('Object ID');
//     // final ipAddress = getField('IP Address');
//     final isCheckOut = widget.isCheckOut;

//     const grey555 = PdfColor.fromInt(0xFF555555);
//     const greyDDD = PdfColor.fromInt(0xFFDDDDDD);
//     const greyF0 = PdfColor.fromInt(0xFFF0F0F0);
//     const greyF5 = PdfColor.fromInt(0xFFF5F5F5);
//     const white = PdfColors.white;
//     const actionBlue = PdfColor.fromInt(0xFF1A73E8);
//     const actionGreen = PdfColor.fromInt(0xFF00C48C);

//     final baseFont = sarabunRegular ?? pw.Font.helvetica();
//     final boldFont = sarabunBold ?? pw.Font.helveticaBold();

//     pw.TextStyle ts({
//       double size = 10,
//       pw.Font? font,
//       PdfColor color = PdfColors.black,
//       double? lineSpacing,
//     }) =>
//         pw.TextStyle(
//           font: font ?? baseFont,
//           fontSize: size,
//           color: color,
//           lineSpacing: lineSpacing,
//         );

//     pw.Widget fieldRow(
//       String label1,
//       String value1, {
//       String? label2,
//       String? value2,
//       double minW1 = 80,
//       double minW2 = 68,
//       bool underline1 = true,
//       bool underline2 = true,
//     }) {
//       final children = <pw.Widget>[
//         pw.SizedBox(
//           width: minW1,
//           child: pw.Text(label1, style: ts(font: boldFont)),
//         ),
//         pw.Expanded(
//           child: pw.Container(
//             decoration: underline1
//                 ? const pw.BoxDecoration(
//                     border: pw.Border(
//                       bottom: pw.BorderSide(color: PdfColors.grey, width: 0.5),
//                     ),
//                   )
//                 : null,
//             padding: const pw.EdgeInsets.only(bottom: 1),
//             child: pw.Text(value1, style: ts()),
//           ),
//         ),
//       ];
//       if (label2 != null && value2 != null) {
//         children.addAll([
//           pw.SizedBox(width: 8),
//           pw.SizedBox(
//             width: minW2,
//             child: pw.Text(label2, style: ts(font: boldFont)),
//           ),
//           pw.Expanded(
//             child: pw.Container(
//               decoration: underline2
//                   ? const pw.BoxDecoration(
//                       border: pw.Border(
//                         bottom:
//                             pw.BorderSide(color: PdfColors.grey, width: 0.5),
//                       ),
//                     )
//                   : null,
//               padding: const pw.EdgeInsets.only(bottom: 1),
//               child: pw.Text(value2, style: ts()),
//             ),
//           ),
//         ]);
//       }
//       return pw.Padding(
//         padding: const pw.EdgeInsets.only(bottom: 9),
//         child: pw.Row(
//           crossAxisAlignment: pw.CrossAxisAlignment.end,
//           children: children,
//         ),
//       );
//     }

//     final doc = pw.Document();

//     pw.Widget buildHeader() {
//       return pw.Stack(
//         children: [
//           // ชื่อบริษัท/ชื่อฟอร์ม — กึ่งกลางเป๊ะของความกว้างทั้งหมด ไม่ขึ้นกับฝั่งซ้าย-ขวา
//           pw.Center(
//             child: pw.Column(
//               children: [
//                 pw.Text(AppConstants.companyName,
//                     style: ts(size: 12, font: boldFont),
//                     textAlign: pw.TextAlign.center),
//                 pw.SizedBox(height: 2),
//                 pw.Text(AppConstants.assetProfileTitle,
//                     style: ts(size: 14, font: boldFont),
//                     textAlign: pw.TextAlign.center),
//               ],
//             ),
//           ),
//           // โลโก้ — ชิดซ้ายบนสุด
//           if (logoBytes != null)
//             pw.Positioned(
//               left: 0,
//               top: 0,
//               child: pw.Image(pw.MemoryImage(logoBytes), height: 40),
//             ),
//           // Revision label — ชิดขวาบนสุด
//           pw.Positioned(
//             right: 0,
//             top: 0,
//             child: pw.Text(AppConstants.formRevisionLabel,
//                 style: ts(size: 8, color: grey555)),
//           ),
//         ],
//       );
//     }

//     const accentNavyText = PdfColor.fromInt(0xFF1A3A6B);

//     pw.Widget buildDeviceTypeAndAssetNumber() {
//       return pw.Column(
//         children: [
//           // กล่องที่ 1: checkbox ประเภทอุปกรณ์
//           pw.Container(
//             width: double.infinity,
//             padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 5),
//             decoration: pw.BoxDecoration(
//               color: greyF0,
//               border: pw.Border.all(width: 1.5),
//             ),
//             child: pw.Row(
//               children: [
//                 for (var i = 0;
//                     i < AppConstants.assetDeviceTypeOptions.length;
//                     i++) ...[
//                   if (i > 0) pw.SizedBox(width: 20),
//                   _pdfCheckbox(
//                     AppConstants.assetDeviceTypeOptions[i],
//                     checked: AppConstants.assetDeviceTypeOptions[i] ==
//                         AppConstants.resolveAssetDeviceType(
//                             asset.category?.name, asset.model?.name),
//                     baseFont: baseFont,
//                     boldFont: boldFont,
//                   ),
//                 ],
//               ],
//             ),
//           ),
//           pw.SizedBox(height: 8),
//           // กล่องที่ 2: Asset Number (แยกออกมาต่างหาก มีขอบครบ 4 ด้าน)
//           pw.Container(
//             width: double.infinity,
//             padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
//             decoration: pw.BoxDecoration(
//               border: pw.Border.all(width: 1.5),
//             ),
//             child: pw.Row(
//               children: [
//                 pw.Text('Asset Number:  ',
//                     style: pw.TextStyle(
//                       font: pw.Font.helveticaBoldOblique(),
//                       fontSize: 12,
//                       color: accentNavyText,
//                     )),
//                 pw.Text(tag,
//                     style: pw.TextStyle(
//                       font: pw.Font.helveticaBoldOblique(),
//                       fontSize: 14,
//                       color: accentNavyText,
//                     )),
//               ],
//             ),
//           ),
//         ],
//       );
//     }

//     pw.Widget buildHardwareSection() {
//       return pw.Container(
//         decoration: pw.BoxDecoration(
//           border: pw.Border.all(width: 1.5),
//         ),
//         child: pw.Column(
//           children: [
//             pw.Container(
//               width: double.infinity,
//               color: grey555,
//               padding: const pw.EdgeInsets.symmetric(vertical: 5),
//               child: pw.Text(
//                 AppConstants.hardwareDetailsHeader,
//                 style: ts(size: 11, font: boldFont, color: white),
//                 textAlign: pw.TextAlign.center,
//               ),
//             ),
//             pw.Container(
//               padding: const pw.EdgeInsets.fromLTRB(12, 8, 12, 12),
//               child: pw.Column(
//                 crossAxisAlignment: pw.CrossAxisAlignment.stretch,
//                 children: [
//                   fieldRow('Brand Name :', manufacturer,
//                       label2: 'Model :', value2: model),
//                   fieldRow('S/N :', serial),
//                   fieldRow('Harddisk :', '$storageType $capacity'.trim(),
//                       label2: 'RAM :', value2: ram),
//                   fieldRow('Monitor :', monitor),
//                   fieldRow('S/N :', monitorSerial,
//                       label2: 'Type :', value2: monitorType),
//                   pw.SizedBox(height: 6),
//                   fieldRow('Warranty :', warrantyPeriod, underline1: false),
//                   fieldRow('Warranty :', warrantyProvider,
//                       label2: 'Object ID :',
//                       value2: objectId,
//                       underline1: false,
//                       underline2: false),
//                   fieldRow('PO Number :', poNumber,
//                       minW1: 80, underline1: false),
//                 ],
//               ),
//             ),
//           ],
//         ),
//       );
//     }

//     pw.Widget buildRemarkSection() {
//       return pw.Container(
//         padding: const pw.EdgeInsets.all(10),
//         decoration: pw.BoxDecoration(
//           border: pw.Border.all(width: 1.5),
//         ),
//         child: pw.Column(
//           crossAxisAlignment: pw.CrossAxisAlignment.start,
//           children: [
//             pw.RichText(
//               text: pw.TextSpan(
//                 children: [
//                   pw.TextSpan(
//                       text: 'Remark: ', style: ts(size: 9, font: boldFont)),
//                   pw.TextSpan(
//                     text: AppConstants.checkoutRemarkEn,
//                     style: ts(size: 9),
//                   ),
//                 ],
//               ),
//             ),
//             pw.SizedBox(height: 6),
//             pw.RichText(
//               text: pw.TextSpan(
//                 children: [
//                   pw.TextSpan(
//                       text:
//                           '\u0e2b\u0e21\u0e32\u0e22\u0e40\u0e2b\u0e15\u0e38: ',
//                       style: ts(size: 9, font: boldFont, lineSpacing: 4)),
//                   pw.TextSpan(
//                     text: AppConstants.checkoutRemarkTh,
//                     style: ts(size: 9, lineSpacing: 4),
//                   ),
//                 ],
//               ),
//             ),
//           ],
//         ),
//       );
//     }

//     pw.Widget buildSignatureCell({
//       required Uint8List? sigImageBytes,
//       required String? date,
//     }) {
//       final hasSig = sigImageBytes != null;
//       return pw.Container(
//         height: 110,
//         padding: const pw.EdgeInsets.all(8),
//         child: pw.Column(
//           mainAxisAlignment: pw.MainAxisAlignment.end,
//           crossAxisAlignment: pw.CrossAxisAlignment.start,
//           children: [
//             pw.Expanded(
//               child: hasSig
//                   ? pw.Align(
//                       alignment: pw.Alignment.center,
//                       child: pw.Image(
//                         pw.MemoryImage(sigImageBytes),
//                         height: 45,
//                         fit: pw.BoxFit.contain,
//                       ),
//                     )
//                   : pw.Center(
//                       child: pw.Text('ยังไม่มีลายเซ็น',
//                           style: ts(size: 8, color: PdfColors.grey400)),
//                     ),
//             ),
//             pw.Divider(color: PdfColors.grey300, thickness: 0.5, height: 6),
//             pw.Row(
//               children: [
//                 pw.Text('Date  ', style: ts(size: 8, font: boldFont)),
//                 pw.Expanded(
//                   child:
//                       pw.Text(hasSig ? (date ?? '—') : '', style: ts(size: 9)),
//                 ),
//               ],
//             ),
//           ],
//         ),
//       );
//     }

//     pw.Widget buildSignatureSection() {
//       final checkoutName =
//           isCheckOut ? assigneeName : priorCheckout?.assigneeName;
//       final checkoutDivision = isCheckOut ? division : priorCheckout?.division;
//       final checkoutDate = isCheckOut ? dateStr : priorCheckout?.dateStr;
//       final checkoutSig = isCheckOut ? sigBytes : priorCheckout?.sigBytes;

//       final checkinDate = isCheckOut ? null : dateStr;
//       final checkinSig = isCheckOut ? null : sigBytes;

//       final displayName = checkoutName ?? assigneeName;
//       final displayDivision = checkoutDivision ?? division;

//       return pw.Table(
//         border: pw.TableBorder.all(width: 1.5),
//         columnWidths: {
//           0: const pw.FlexColumnWidth(2.2),
//           1: const pw.FlexColumnWidth(1.3),
//           2: const pw.FlexColumnWidth(2.5),
//           3: const pw.FlexColumnWidth(2.5),
//         },
//         children: [
//           pw.TableRow(
//             decoration: pw.BoxDecoration(color: greyDDD),
//             children: [
//               _tableHeader('Name', boldFont: boldFont, ts: ts),
//               _tableHeader('Division', boldFont: boldFont, ts: ts),
//               _tableHeader('Receive', boldFont: boldFont, ts: ts),
//               _tableHeader('Return', boldFont: boldFont, ts: ts),
//             ],
//           ),
//           pw.TableRow(
//             children: [
//               pw.Padding(
//                 padding: const pw.EdgeInsets.all(8),
//                 child: pw.Align(
//                   alignment: pw.Alignment.topCenter,
//                   child: pw.Text(
//                     displayName ?? '—',
//                     style: ts(font: boldFont),
//                     textAlign: pw.TextAlign.center,
//                   ),
//                 ),
//               ),
//               pw.Padding(
//                 padding: const pw.EdgeInsets.all(8),
//                 child: pw.Align(
//                   alignment: pw.Alignment.topCenter,
//                   child: pw.Text(
//                     displayDivision ?? '—',
//                     style: ts(),
//                     textAlign: pw.TextAlign.center,
//                   ),
//                 ),
//               ),
//               buildSignatureCell(
//                 sigImageBytes: checkoutSig,
//                 date: checkoutDate,
//               ),
//               buildSignatureCell(
//                 sigImageBytes: checkinSig,
//                 date: checkinDate,
//               ),
//             ],
//           ),
//         ],
//       );
//     }

//     pw.Widget buildVerificationSection() {
//       return pw.Container(
//         decoration: pw.BoxDecoration(
//           border: pw.Border.all(width: 1.5),
//         ),
//         child: pw.Row(
//           crossAxisAlignment: pw.CrossAxisAlignment.start,
//           children: [
//             pw.Container(
//               width: 110,
//               padding: const pw.EdgeInsets.all(10),
//               decoration: const pw.BoxDecoration(
//                 border: pw.Border(
//                   right: pw.BorderSide(width: 1.5),
//                 ),
//               ),
//               child: pw.Column(
//                 children: [
//                   pw.Image(pw.MemoryImage(qrPngBytes), width: 85, height: 85),
//                   pw.SizedBox(height: 4),
//                   pw.Text(AppConstants.scanToVerify,
//                       style: ts(size: 7, color: grey555),
//                       textAlign: pw.TextAlign.center),
//                 ],
//               ),
//             ),
//             pw.Expanded(
//               child: pw.Padding(
//                 padding: const pw.EdgeInsets.all(10),
//                 child: pw.Column(
//                   crossAxisAlignment: pw.CrossAxisAlignment.start,
//                   children: [
//                     pw.Text(AppConstants.verificationHeader,
//                         style: ts(size: 8, font: boldFont, color: grey555)),
//                     pw.SizedBox(height: 6),
//                     pw.Text(verifyCode,
//                         style: pw.TextStyle(
//                           font: boldFont,
//                           fontSize: 16,
//                           letterSpacing: 4,
//                         )),
//                     pw.SizedBox(height: 6),
//                     pw.Text(
//                       'This code is generated from asset tag, recipient name, date, action and signature image hash. '
//                       'Any modification to this document will invalidate this code.',
//                       style: ts(size: 8, color: grey555),
//                     ),
//                     pw.SizedBox(height: 6),
//                     pw.Container(
//                       padding: const pw.EdgeInsets.symmetric(
//                           horizontal: 8, vertical: 5),
//                       decoration: pw.BoxDecoration(
//                         color: greyF5,
//                         borderRadius: pw.BorderRadius.circular(3),
//                       ),
//                       child: pw.Text(
//                         'ASSET: $tag  |  ACTION: $action  |  DATE: $dateStr  |  S/N: $serial',
//                         style: pw.TextStyle(
//                           font: baseFont,
//                           fontSize: 7,
//                           color: grey555,
//                         ),
//                       ),
//                     ),
//                   ],
//                 ),
//               ),
//             ),
//           ],
//         ),
//       );
//     }

//     pw.Widget buildFooter() {
//       return pw.Text(
//         AppConstants.footerCredit,
//         style: ts(size: 8, color: grey555),
//         textAlign: pw.TextAlign.right,
//       );
//     }

//     doc.addPage(
//       pw.Page(
//         pageFormat: PdfPageFormat.a4,
//         margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
//         build: (context) {
//           return pw.Column(
//             crossAxisAlignment: pw.CrossAxisAlignment.stretch,
//             children: [
//               buildHeader(),
//               pw.SizedBox(height: 8),
//               buildDeviceTypeAndAssetNumber(),
//               pw.SizedBox(height: 8),
//               buildHardwareSection(),
//               pw.SizedBox(height: 8),
//               buildRemarkSection(),
//               pw.SizedBox(height: 14),
//               buildSignatureSection(),
//               pw.SizedBox(height: 14),
//               buildVerificationSection(),
//               pw.Spacer(),
//               buildFooter(),
//             ],
//           );
//         },
//       ),
//     );

//     return doc.save();
//   }

//   // ── PDF helpers ────────────────────────────────────────────────────────────

//   pw.Widget _pdfCheckbox(
//     String label, {
//     bool checked = false,
//     required pw.Font baseFont,
//     required pw.Font boldFont,
//   }) {
//     return pw.Row(
//       children: [
//         pw.Container(
//           width: 12,
//           height: 12,
//           decoration: pw.BoxDecoration(
//             border: pw.Border.all(width: 1.5),
//             color:
//                 checked ? const PdfColor.fromInt(0xFF333333) : PdfColors.white,
//           ),
//         ),
//         pw.SizedBox(width: 5),
//         pw.Text(label, style: pw.TextStyle(font: boldFont, fontSize: 10)),
//       ],
//     );
//   }

//   pw.Widget _tableHeader(
//     String text, {
//     required pw.Font boldFont,
//     required _PdfTextStyleBuilder ts,
//   }) {
//     return pw.Padding(
//       padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
//       child: pw.Text(text,
//           style: ts(font: boldFont), textAlign: pw.TextAlign.center),
//     );
//   }

//   // ── Download / share PDF ────────────────────────────────────────────────────

//   String _sanitizeForFilename(String input) {
//     final cleaned = input
//         .trim()
//         .replaceAll(RegExp(r'[^\w\u0E00-\u0E7F]+'), '_')
//         .replaceAll(RegExp(r'_+'), '_')
//         .replaceAll(RegExp(r'^_|_$'), '');
//     return cleaned.isEmpty ? 'Unknown' : cleaned;
//   }

//   Future<void> _downloadPdfFile(
//     Uint8List pdfBytes,
//     String action,
//     DateTime now,
//     AssetModel asset,
//     String assigneeName,
//   ) async {
//     final mm = now.month.toString().padLeft(2, '0');
//     final dd = now.day.toString().padLeft(2, '0');
//     final yyyy = now.year.toString();

//     final tag = _sanitizeForFilename(asset.assetTag ?? 'Unknown');
//     final user = _sanitizeForFilename(assigneeName);
//     final actionLabel = action.toLowerCase();

//     final filename = '${tag}_${user}_$yyyy$mm${dd}_$actionLabel.pdf';

//     try {
//       await downloadOrSharePdf(pdfBytes, filename);
//       debugPrint('=== [Download PDF] success: $filename');
//     } catch (e, st) {
//       debugPrint('=== [Download PDF] error: $e\n$st');
//       if (mounted) {
//         setState(() {
//           _exportError = 'PDF could not be saved/shared: $e';
//         });
//       }
//     }
//   }

//   // ── Build UI ───────────────────────────────────────────────────────────────

//   @override
//   Widget build(BuildContext context) {
//     return Dialog(
//       insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
//       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
//       child: Column(
//         mainAxisSize: MainAxisSize.min,
//         crossAxisAlignment: CrossAxisAlignment.stretch,
//         children: [
//           // ── Header (fixed) ────────────────────────────────────────
//           Container(
//             padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
//             decoration: const BoxDecoration(
//               color: AppConstants.primaryNavy,
//               borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
//             ),
//             child: Row(
//               children: [
//                 const Icon(Icons.draw_outlined,
//                     color: Colors.white70, size: 20),
//                 const SizedBox(width: 10),
//                 Expanded(
//                   child: Column(
//                     crossAxisAlignment: CrossAxisAlignment.start,
//                     children: [
//                       Text(widget.title,
//                           style: const TextStyle(
//                               color: Colors.white,
//                               fontSize: 16,
//                               fontWeight: FontWeight.w600)),
//                       if (widget.subtitle != null) ...[
//                         const SizedBox(height: 2),
//                         Text(widget.subtitle!,
//                             style: const TextStyle(
//                                 color: Colors.white60, fontSize: 12)),
//                       ],
//                     ],
//                   ),
//                 ),
//                 IconButton(
//                   icon: const Icon(Icons.close, color: Colors.white60),
//                   onPressed: () => Navigator.of(context).pop(null),
//                 ),
//               ],
//             ),
//           ),

//           // ── Scrollable content ────────────────────────────────────
//           Flexible(
//             child: SingleChildScrollView(
//               child: Column(
//                 crossAxisAlignment: CrossAxisAlignment.stretch,
//                 children: [
//                   if (widget.asset != null)
//                     Padding(
//                       padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
//                       child: Container(
//                         padding: const EdgeInsets.all(12),
//                         decoration: BoxDecoration(
//                           color: AppConstants.accentBlue.withOpacity(0.06),
//                           borderRadius: BorderRadius.circular(8),
//                           border: Border.all(
//                               color: AppConstants.accentBlue.withOpacity(0.2)),
//                         ),
//                         child: Column(
//                           crossAxisAlignment: CrossAxisAlignment.start,
//                           children: [
//                             Row(children: [
//                               const Icon(Icons.laptop_mac,
//                                   size: 14, color: AppConstants.accentBlue),
//                               const SizedBox(width: 6),
//                               Text(
//                                 widget.asset!.name ??
//                                     widget.asset!.assetTag ??
//                                     'Asset',
//                                 style: const TextStyle(
//                                     fontSize: 13,
//                                     fontWeight: FontWeight.w600,
//                                     color: AppConstants.textPrimary),
//                               ),
//                             ]),
//                             const SizedBox(height: 4),
//                             Text(
//                               'S/N: ${widget.asset!.serial ?? '—'}  |  Tag: ${widget.asset!.assetTag ?? '—'}',
//                               style: const TextStyle(
//                                   fontSize: 11,
//                                   color: AppConstants.textSecondary),
//                             ),
//                             if (widget.assigneeName != null) ...[
//                               const SizedBox(height: 4),
//                               Text(
//                                 '${widget.isCheckOut ? 'Recipient' : 'Returned by'}: ${widget.assigneeName}'
//                                 '${widget.division != null ? ' (${widget.division})' : ''}',
//                                 style: const TextStyle(
//                                     fontSize: 11,
//                                     color: AppConstants.textSecondary),
//                               ),
//                             ],
//                           ],
//                         ),
//                       ),
//                     ),
//                   if (widget.isCheckOut)
//                     Padding(
//                       padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
//                       child: Container(
//                         padding: const EdgeInsets.all(12),
//                         decoration: BoxDecoration(
//                           color: AppConstants.accentAmber.withOpacity(0.07),
//                           borderRadius: BorderRadius.circular(8),
//                           border: Border.all(
//                               color: AppConstants.accentAmber.withOpacity(0.4)),
//                         ),
//                         child: const Column(
//                           crossAxisAlignment: CrossAxisAlignment.start,
//                           children: [
//                             Row(children: [
//                               Icon(Icons.info_outline,
//                                   size: 14, color: AppConstants.accentAmber),
//                               SizedBox(width: 6),
//                               Text(
//                                 'ข้อตกลงการรับอุปกรณ์',
//                                 style: TextStyle(
//                                     fontSize: 12,
//                                     fontWeight: FontWeight.w700,
//                                     color: AppConstants.accentAmber),
//                               ),
//                             ]),
//                             SizedBox(height: 6),
//                             Text(
//                               'Remark: The employee acknowledges that the Hardware received is the property of Stream I.T. Consulting Ltd. '
//                               'The employee agrees to take care of and maintain the Hardware and a standard no lower than that which a person, '
//                               'in general, would be expected to maintain. The hardware is possessed by the employee for work only.',
//                               style: TextStyle(
//                                   fontSize: 11,
//                                   color: AppConstants.textPrimary,
//                                   height: 1.5),
//                             ),
//                             SizedBox(height: 6),
//                             Text(
//                               'หมายเหตุ: พนักงานยอมรับทราบว่าฮาร์ดแวร์ที่ได้รับเป็นกรรมสิทธิ์ของบริษัท พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์'
//                               'ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา โดยฮาร์ดแวร์ที่ได้รับนี้พนักงานรับทราบว่ามีไว้สำหรับใช้ในการทำงานเท่านั้น',
//                               style: TextStyle(
//                                   fontSize: 11,
//                                   color: AppConstants.textPrimary,
//                                   height: 1.5),
//                             ),
//                           ],
//                         ),
//                       ),
//                     ),
//                   const Padding(
//                     padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
//                     child: Text(
//                       'Sign in the box below',
//                       style: TextStyle(
//                           color: AppConstants.textSecondary, fontSize: 13),
//                     ),
//                   ),
//                   if (_exportError != null)
//                     Padding(
//                       padding: const EdgeInsets.symmetric(
//                           horizontal: 16, vertical: 4),
//                       child: Container(
//                         padding: const EdgeInsets.all(10),
//                         decoration: BoxDecoration(
//                           color: AppConstants.accentRed.withOpacity(0.1),
//                           borderRadius: BorderRadius.circular(8),
//                           border: Border.all(
//                               color: AppConstants.accentRed.withOpacity(0.4)),
//                         ),
//                         child: Text(_exportError!,
//                             style: const TextStyle(
//                                 color: AppConstants.accentRed, fontSize: 12)),
//                       ),
//                     ),

//                   // FIX: ครอบด้วย Center + ConstrainedBox เพื่อจำกัดความกว้างสูงสุดของบอร์ดเซ็นบน Web/Tablet ไม่ให้ยืดกว้างเกินสัดส่วนจริงจนลายเซ็นเบี้ยว
//                   Padding(
//                     padding: const EdgeInsets.symmetric(horizontal: 16),
//                     child: Center(
//                       child: ConstrainedBox(
//                         constraints: const BoxConstraints(maxWidth: 500),
//                         child: Container(
//                           height: 220,
//                           decoration: BoxDecoration(
//                             color: Colors.white,
//                             border: Border.all(
//                               color: _isEmpty
//                                   ? AppConstants.divider
//                                   : AppConstants.accentBlue,
//                               width: _isEmpty ? 1.5 : 2,
//                             ),
//                             borderRadius: BorderRadius.circular(10),
//                           ),
//                           clipBehavior: Clip.hardEdge,
//                           child: Stack(
//                             children: [
//                               Signature(
//                                 controller: _controller,
//                                 backgroundColor: Colors.white,
//                               ),
//                               Positioned(
//                                 bottom: 36,
//                                 left: 24,
//                                 right: 24,
//                                 child: Container(
//                                     height: 1, color: AppConstants.divider),
//                               ),
//                               if (_isEmpty)
//                                 const Center(
//                                   child: Text('Sign here',
//                                       style: TextStyle(
//                                           color: AppConstants.divider,
//                                           fontSize: 16,
//                                           fontWeight: FontWeight.w300)),
//                                 ),
//                             ],
//                           ),
//                         ),
//                       ),
//                     ),
//                   ),
//                   const Padding(
//                     padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
//                     child: Row(
//                       children: [
//                         Icon(Icons.picture_as_pdf_outlined,
//                             size: 13, color: AppConstants.textSecondary),
//                         SizedBox(width: 5),
//                         Text(
//                           'Document will be downloaded as PDF',
//                           style: TextStyle(
//                               fontSize: 11, color: AppConstants.textSecondary),
//                         ),
//                       ],
//                     ),
//                   ),
//                 ],
//               ),
//             ),
//           ),

//           // ── Actions (fixed) ───────────────────────────────────────
//           Padding(
//             padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
//             child: Row(
//               children: [
//                 OutlinedButton.icon(
//                   onPressed: () {
//                     _controller.clear();
//                     setState(() {
//                       _isEmpty = true;
//                       _exportError = null;
//                     });
//                   },
//                   icon: const Icon(Icons.refresh, size: 18),
//                   label: const Text('Clear'),
//                   style: OutlinedButton.styleFrom(
//                     foregroundColor: AppConstants.textSecondary,
//                     side: const BorderSide(color: AppConstants.divider),
//                   ),
//                 ),
//                 const SizedBox(width: 12),
//                 Expanded(
//                   child: ElevatedButton.icon(
//                     onPressed: (!_isEmpty && !_isExporting) ? _confirm : null,
//                     icon: _isExporting
//                         ? const SizedBox(
//                             width: 16,
//                             height: 16,
//                             child: CircularProgressIndicator(
//                                 strokeWidth: 2, color: Colors.white))
//                         : const Icon(Icons.picture_as_pdf_outlined, size: 18),
//                     label: Text(
//                       _isExporting ? 'Generating\u2026' : 'Confirm & Save',
//                       overflow: TextOverflow.ellipsis,
//                       maxLines: 1,
//                     ),
//                     style: ElevatedButton.styleFrom(
//                       padding: const EdgeInsets.symmetric(horizontal: 12),
//                     ),
//                   ),
//                 ),
//               ],
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
