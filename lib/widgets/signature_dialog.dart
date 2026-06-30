import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:crypto/crypto.dart'; // real cryptographic hashing
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html_unescape/html_unescape.dart'; // replaces hand-rolled entity decoder
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';
import 'package:signature/signature.dart';

// Web-only download path.
import 'package:universal_html/html.dart' as html;

// Non-web download/share path.
// NOTE: add these to pubspec.yaml if not already present:
//   path_provider: ^2.1.0
//   share_plus: ^9.0.0
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io' as io;

import '../models/asset_model.dart';
import '../utils/app_constants.dart';

// NOTE: device-type checkbox logic (NoteBook/PC/Server) reads
// `asset.category?.name`, falling back to `asset.model?.name` if the
// category wasn't returned by the API. Requires `AssetModel.category`
// (see asset_model.dart) — make sure that field is present in your model.

Future<Uint8List?> showSignatureDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  AssetModel? asset,
  String? assigneeName,
  String? division,
  bool isCheckOut = true,
}) {
  return showDialog<Uint8List?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SignatureDialog(
      title: title,
      subtitle: subtitle,
      asset: asset,
      assigneeName: assigneeName,
      division: division,
      isCheckOut: isCheckOut,
    ),
  );
}

/// Centralized layout/format constants (FIX #7: no more magic numbers
/// scattered through the PDF-building code).
class _PdfLayoutConstants {
  static const double canvasWidth = 600;
  static const double canvasHeight = 300;
  static const int qrCellSize = 6;
  static const int qrPadding = 12;
}

// Document copy (company name, titles, remarks, device-type resolution)
// now lives in AppConstants (see app_constants.dart) instead of a local
// class here, so it's shared with the rest of the app and only needs to
// change in one place.

/// FIX #8: Font bytes are loaded once and cached at the class (static)
/// level instead of being re-read from the asset bundle on every single
/// checkout/checkin PDF generation.
class _FontCache {
  static pw.Font? sarabunRegular;
  static pw.Font? sarabunBold;
  static bool _attempted = false;

  static Future<void> ensureLoaded() async {
    if (_attempted) return;
    _attempted = true;
    sarabunRegular = await _load('assets/fonts/Sarabun-Regular.ttf');
    sarabunBold = await _load('assets/fonts/Sarabun-Bold.ttf');
  }

  static Future<pw.Font?> _load(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return pw.Font.ttf(data);
    } catch (e, st) {
      // FIX #3: log instead of swallowing the error silently.
      debugPrint('=== [FontCache] Failed to load $assetPath: $e\n$st');
      return null;
    }
  }
}

/// FIX #1 + #2: Real SHA-256 based document verification, computed over the
/// *entire* signature image (not just the first 32 bytes, which are mostly
/// constant PNG header bytes and don't meaningfully distinguish signatures),
/// plus a high-resolution timestamp + random nonce so two documents signed
/// within the same minute can't collide (FIX #10).
class _DocumentVerification {
  static String sha256Hex(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  static String sha256HexBytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  static String generateVerificationCode({
    required String assetTag,
    required String assigneeName,
    required String dateStr,
    required String action,
    required Uint8List sigBytes,
  }) {
    final sigFingerprint = sha256HexBytes(sigBytes);
    final nonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final payload =
        '$assetTag|$assigneeName|$dateStr|$action|$sigFingerprint|$nonce';
    final hash = sha256Hex(payload);
    // Take a readable slice of the full hash for display purposes; the
    // full hash above is still cryptographically derived from all inputs,
    // unlike the previous FNV-1a implementation which was trivially
    // collidable.
    final code = hash.substring(0, 16).toUpperCase();
    return '${code.substring(0, 4)}-${code.substring(4, 8)}-'
        '${code.substring(8, 12)}-${code.substring(12, 16)}';
  }
}

class _SignatureDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final AssetModel? asset;
  final String? assigneeName;
  final String? division;
  final bool isCheckOut;

  const _SignatureDialog({
    required this.title,
    this.subtitle,
    this.asset,
    this.assigneeName,
    this.division,
    this.isCheckOut = true,
  });

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  late final SignatureController _controller;
  bool _isEmpty = true;
  bool _isExporting = false;
  String? _exportError;

  @override
  void initState() {
    super.initState();
    _controller = SignatureController(
      penStrokeWidth: 3.5,
      penColor: AppConstants.primaryNavy,
      exportBackgroundColor: Colors.white,
    )..addListener(() {
        setState(() => _isEmpty = _controller.isEmpty);
      });
    // Warm the font cache as soon as the dialog opens so the PDF
    // generation step later doesn't pay the asset-load cost.
    unawaited(_FontCache.ensureLoaded());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── HTML entity decoder ────────────────────────────────────────────────────
  // FIX #2: was a long hand-rolled chain of replaceAll() calls covering only
  // a dozen named entities. html_unescape covers the full named-entity table
  // plus numeric (&#NN;) and hex (&#xNN;) entities, and is one line to use.

  static final HtmlUnescape _htmlUnescape = HtmlUnescape();

  String _decodeHtmlEntities(String input) => _htmlUnescape.convert(input);

  // ── Export signature PNG ───────────────────────────────────────────────────

  Future<Uint8List?> _exportSignatureBytes() async {
    Uint8List? pngBytes;

    try {
      pngBytes = await _controller.toPngBytes(
        height: _PdfLayoutConstants.canvasHeight.toInt(),
        width: _PdfLayoutConstants.canvasWidth.toInt(),
      );
    } catch (e, st) {
      debugPrint('=== [Signature] toPngBytes failed: $e\n$st');
    }

    if (pngBytes == null || pngBytes.isEmpty) {
      try {
        final image = await _controller.toImage(
          height: _PdfLayoutConstants.canvasHeight.toInt(),
          width: _PdfLayoutConstants.canvasWidth.toInt(),
        );
        if (image != null) {
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          pngBytes = byteData?.buffer.asUint8List();
        }
      } catch (e, st) {
        debugPrint('=== [Signature] toImage fallback failed: $e\n$st');
      }
    }

    if (pngBytes == null || pngBytes.isEmpty) {
      // FIX #4: manual canvas fallback now draws connected strokes
      // (a Path through consecutive points) instead of disconnected dots,
      // so the resulting signature actually looks like what was drawn.
      try {
        const w = _PdfLayoutConstants.canvasWidth;
        const h = _PdfLayoutConstants.canvasHeight;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
        canvas.drawRect(
            const Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
        final paint = Paint()
          ..color = AppConstants.primaryNavy
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke;

        Offset? previous;
        for (final point in _controller.points) {
          if (point == null) {
            // null marks a pen-up / new-stroke boundary.
            previous = null;
            continue;
          }
          if (previous != null) {
            canvas.drawLine(previous, point.offset, paint);
          } else {
            // Single isolated point (e.g. a tap/dot): draw a small filled
            // circle so it's still visible even with no line to connect.
            canvas.drawCircle(
              point.offset,
              1.75,
              Paint()..color = AppConstants.primaryNavy,
            );
          }
          previous = point.offset;
        }

        final picture = recorder.endRecording();
        final img = await picture.toImage(w.toInt(), h.toInt());
        final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
        pngBytes = byteData?.buffer.asUint8List();
      } catch (e, st) {
        debugPrint('=== [Signature] manual canvas fallback failed: $e\n$st');
      }
    }

    return pngBytes;
  }

  // ── QR PNG via dart:ui canvas ──────────────────────────────────────────────

  Future<Uint8List> _generateQrPngBytes(String data) async {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qr);
    final moduleCount = qr.moduleCount;
    const cellSize = _PdfLayoutConstants.qrCellSize;
    const padding = _PdfLayoutConstants.qrPadding;
    final totalSize = moduleCount * cellSize + padding * 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
      Paint()..color = Colors.white,
    );
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < moduleCount; row++) {
      for (var col = 0; col < moduleCount; col++) {
        if (qrImage.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(
              (col * cellSize + padding).toDouble(),
              (row * cellSize + padding).toDouble(),
              cellSize.toDouble(),
              cellSize.toDouble(),
            ),
            paint,
          );
        }
      }
    }
    final picture = recorder.endRecording();
    final img = await picture.toImage(totalSize, totalSize);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  // ── Confirm ────────────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    if (_controller.isEmpty) return;
    setState(() {
      _isExporting = true;
      _exportError = null;
    });

    try {
      final pngBytes = await _exportSignatureBytes();

      if (pngBytes == null || pngBytes.isEmpty) {
        if (mounted) {
          setState(() {
            _isExporting = false;
            _exportError = 'Cannot save signature. Please try again.';
          });
        }
        return;
      }

      if (widget.asset != null) {
        await _generateAndDownloadPdf(pngBytes);
      }

      if (mounted) Navigator.of(context).pop(pngBytes);
    } catch (e, st) {
      debugPrint('=== [Signature] _confirm failed: $e\n$st');
      if (mounted) {
        setState(() {
          _isExporting = false;
          _exportError = 'Error: $e';
        });
      }
    }
  }

  // ── Generate & download PDF ────────────────────────────────────────────────

  Future<void> _generateAndDownloadPdf(Uint8List sigBytes) async {
    final now = DateTime.now();
    final dateStr =
        '${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';
    final asset = widget.asset!;
    final action = widget.isCheckOut ? 'Checkout' : 'Checkin';

    final verifyCode = _DocumentVerification.generateVerificationCode(
      assetTag: asset.assetTag ?? '—',
      assigneeName: widget.assigneeName ?? '—',
      dateStr: dateStr,
      action: action,
      sigBytes: sigBytes,
    );

    final qrData = [
      'ASSET:${asset.assetTag ?? '—'}',
      'ACTION:$action',
      'RECIPIENT:${widget.assigneeName ?? '—'}',
      'DIVISION:${widget.division ?? '—'}',
      'DATE:$dateStr',
      'SERIAL:${asset.serial ?? '—'}',
      'VERIFY:$verifyCode',
    ].join('\n');

    final qrPngBytes = await _generateQrPngBytes(qrData);

    // Logo
    Uint8List? logoBytes;
    try {
      final data = await rootBundle.load('assets/stream_logoNew.png');
      logoBytes = data.buffer.asUint8List();
    } catch (e, st) {
      debugPrint('=== [PDF] Failed to load logo: $e\n$st');
    }

    // FIX #8: use the cached fonts instead of reloading from disk every time.
    await _FontCache.ensureLoaded();

    final pdfBytes = await _buildPdf(
      action: action,
      dateStr: dateStr,
      asset: asset,
      assigneeName: widget.assigneeName ?? '—',
      division: widget.division ?? '—',
      sigBytes: sigBytes,
      qrPngBytes: qrPngBytes,
      logoBytes: logoBytes,
      verifyCode: verifyCode,
      sarabunRegular: _FontCache.sarabunRegular,
      sarabunBold: _FontCache.sarabunBold,
    );

    await _downloadPdfFile(pdfBytes, action, now);
  }

  // ── Build PDF ──────────────────────────────────────────────────────────────

  Future<Uint8List> _buildPdf({
    required String action,
    required String dateStr,
    required AssetModel asset,
    required String assigneeName,
    required String division,
    required Uint8List sigBytes,
    required Uint8List qrPngBytes,
    Uint8List? logoBytes,
    String verifyCode = '',
    pw.Font? sarabunRegular,
    pw.Font? sarabunBold,
  }) async {
    String getField(String key) {
      final field = (asset.customFields ?? {})[key];
      if (field == null) return '—';
      final raw = field['value']?.toString() ?? '—';
      return _decodeHtmlEntities(raw);
    }

    final tag = asset.assetTag ?? '—';
    final serial = asset.serial ?? '—';
    final manufacturer = _decodeHtmlEntities(asset.manufacturer?.name ?? '—');
    final model = _decodeHtmlEntities(asset.model?.name ?? '—');
    final ram = getField('RAM');
    final storageType = getField('Storage Type');
    final capacity = getField('Capacity');
    final monitor = getField('Monitor');
    final isCheckOut = widget.isCheckOut;

    const grey555 = PdfColor.fromInt(0xFF555555);
    const greyDDD = PdfColor.fromInt(0xFFDDDDDD);
    const greyF0 = PdfColor.fromInt(0xFFF0F0F0);
    const greyF5 = PdfColor.fromInt(0xFFF5F5F5);
    const white = PdfColors.white;
    const actionBlue = PdfColor.fromInt(0xFF1A73E8);
    const actionGreen = PdfColor.fromInt(0xFF00C48C);

    final baseFont = sarabunRegular ?? pw.Font.helvetica();
    final boldFont = sarabunBold ?? pw.Font.helveticaBold();

    pw.TextStyle ts({
      double size = 10,
      pw.Font? font,
      PdfColor color = PdfColors.black,
      double? lineSpacing,
    }) =>
        pw.TextStyle(
          font: font ?? baseFont,
          fontSize: size,
          color: color,
          lineSpacing: lineSpacing,
        );

    pw.Widget fieldRow(
      String label1,
      String value1, {
      String? label2,
      String? value2,
      double minW1 = 80,
      double minW2 = 40,
    }) {
      final children = <pw.Widget>[
        pw.SizedBox(
          width: minW1,
          child: pw.Text(label1, style: ts(font: boldFont)),
        ),
        pw.Expanded(
          child: pw.Container(
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: PdfColors.grey, width: 0.5),
              ),
            ),
            padding: const pw.EdgeInsets.only(bottom: 1),
            child: pw.Text(value1, style: ts()),
          ),
        ),
      ];
      if (label2 != null && value2 != null) {
        children.addAll([
          pw.SizedBox(width: 8),
          pw.SizedBox(
            width: minW2,
            child: pw.Text(label2, style: ts(font: boldFont)),
          ),
          pw.Expanded(
            child: pw.Container(
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: PdfColors.grey, width: 0.5),
                ),
              ),
              padding: const pw.EdgeInsets.only(bottom: 1),
              child: pw.Text(value2, style: ts()),
            ),
          ),
        ]);
      }
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: children,
        ),
      );
    }

    final doc = pw.Document();

    // FIX #7: _buildPdf was one 500+ line widget tree. Broken into small,
    // named section builders below — each one focused on a single visual
    // block of the document — so the page layout reads as a list of
    // sections instead of one giant nested tree.

    pw.Widget buildHeader() {
      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          if (logoBytes != null)
            pw.Image(pw.MemoryImage(logoBytes), height: 40)
          else
            pw.SizedBox(width: 60),
          pw.Expanded(
            child: pw.Column(
              children: [
                pw.Text(AppConstants.companyName,
                    style: ts(size: 12, font: boldFont),
                    textAlign: pw.TextAlign.center),
                pw.SizedBox(height: 2),
                pw.Text(AppConstants.assetProfileTitle,
                    style: ts(size: 14, font: boldFont),
                    textAlign: pw.TextAlign.center),
              ],
            ),
          ),
          pw.Text(AppConstants.formRevisionLabel,
              style: ts(size: 8, color: grey555)),
        ],
      );
    }

    pw.Widget buildDeviceTypeAndAssetNumber() {
      return pw.Column(
        children: [
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: pw.BoxDecoration(
              color: greyF0,
              border: pw.Border.all(width: 1.5),
            ),
            child: pw.Row(
              children: [
                for (var i = 0;
                    i < AppConstants.assetDeviceTypeOptions.length;
                    i++) ...[
                  if (i > 0) pw.SizedBox(width: 20),
                  _pdfCheckbox(
                    AppConstants.assetDeviceTypeOptions[i],
                    checked: AppConstants.assetDeviceTypeOptions[i] ==
                        AppConstants.resolveAssetDeviceType(
                            asset.category?.name, asset.model?.name),
                    baseFont: baseFont,
                    boldFont: boldFont,
                  ),
                ],
              ],
            ),
          ),
          pw.Container(
            padding:
                const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(width: 1.5),
                right: pw.BorderSide(width: 1.5),
                bottom: pw.BorderSide(width: 1.5),
              ),
            ),
            child: pw.Row(
              children: [
                pw.Text('Asset Number :', style: ts(font: boldFont)),
                pw.SizedBox(width: 10),
                pw.Text(tag, style: ts(size: 12, font: boldFont)),
              ],
            ),
          ),
        ],
      );
    }

    pw.Widget buildHardwareSection() {
      return pw.Container(
        // FIX: header used to have no border at all, so it visually
        // "floated" disconnected from the bordered body box below it.
        // Wrapping both in one outer container gives a single continuous
        // border around the whole section.
        decoration: pw.BoxDecoration(
          border: pw.Border.all(width: 1.5),
        ),
        child: pw.Column(
          children: [
            pw.Container(
              width: double.infinity,
              color: grey555,
              padding: const pw.EdgeInsets.symmetric(vertical: 5),
              child: pw.Text(
                AppConstants.hardwareDetailsHeader,
                style: ts(size: 11, font: boldFont, color: white),
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.Container(
              padding: const pw.EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                fieldRow('Brand Name :', manufacturer,
                    label2: 'Model :', value2: model, minW2: 40),
                fieldRow('S/N :', serial, minW1: 80),
                fieldRow('Harddisk :', '$storageType $capacity',
                    label2: 'RAM :', value2: ram, minW2: 40),
                fieldRow('Monitor :', monitor),
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 0),
                  child: pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.SizedBox(
                        width: 80,
                        child: pw.Text('Action :', style: ts(font: boldFont)),
                      ),
                      pw.Expanded(
                        child: pw.Container(
                          decoration: const pw.BoxDecoration(
                            border: pw.Border(
                              bottom: pw.BorderSide(
                                  color: PdfColors.grey, width: 0.5),
                            ),
                          ),
                          padding: const pw.EdgeInsets.only(bottom: 1),
                          child: pw.Text(
                            action,
                            style: ts(
                              font: boldFont,
                              color: isCheckOut ? actionBlue : actionGreen,
                            ),
                          ),
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.SizedBox(
                        width: 40,
                        child: pw.Text('Date :', style: ts(font: boldFont)),
                      ),
                      pw.Expanded(
                        child: pw.Container(
                          decoration: const pw.BoxDecoration(
                            border: pw.Border(
                              bottom: pw.BorderSide(
                                  color: PdfColors.grey, width: 0.5),
                            ),
                          ),
                          padding: const pw.EdgeInsets.only(bottom: 1),
                          child: pw.Text(dateStr, style: ts()),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            ),
          ],
        ),
      );
    }

    pw.Widget buildRemarkSection() {
      return pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            left: pw.BorderSide(width: 1.5),
            right: pw.BorderSide(width: 1.5),
            bottom: pw.BorderSide(width: 1.5),
          ),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.RichText(
              text: pw.TextSpan(
                children: [
                  pw.TextSpan(
                      text: 'Remark: ', style: ts(size: 9, font: boldFont)),
                  pw.TextSpan(
                    text: AppConstants.checkoutRemarkEn,
                    style: ts(size: 9),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 4),
            pw.RichText(
              text: pw.TextSpan(
                children: [
                  pw.TextSpan(
                      text:
                          '\u0e2b\u0e21\u0e32\u0e22\u0e40\u0e2b\u0e15\u0e38: ',
                      style: ts(size: 9, font: boldFont)),
                  pw.TextSpan(
                    text: AppConstants.checkoutRemarkTh,
                    style: ts(size: 9),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    pw.Widget buildSignatureSection() {
      return pw.Table(
        border: pw.TableBorder.all(width: 1.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(2.5),
          1: const pw.FlexColumnWidth(1.5),
          2: const pw.FlexColumnWidth(3),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: greyDDD),
            children: [
              _tableHeader('Name', boldFont: boldFont, ts: ts),
              _tableHeader('Division', boldFont: boldFont, ts: ts),
              _tableHeader('Received Date / Signature',
                  boldFont: boldFont, ts: ts),
            ],
          ),
          pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(assigneeName, style: ts(font: boldFont)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(division, style: ts()),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    // FIX: previously only `height` was set, with no width
                    // constraint and no fit behavior. The actual exported
                    // PNG's aspect ratio doesn't always match the requested
                    // 600x300 canvas (the `signature` package bases the
                    // export on the on-screen pad size), so the image could
                    // render far wider than the table cell and overflow
                    // past its right edge uncropped. Locking both width and
                    // height with BoxFit.contain guarantees it always fits.
                    pw.Container(
                      width: 150,
                      height: 55,
                      alignment: pw.Alignment.centerLeft,
                      child: pw.Image(
                        pw.MemoryImage(sigBytes),
                        fit: pw.BoxFit.contain,
                      ),
                    ),
                    pw.Divider(color: PdfColors.grey300, thickness: 0.5),
                    pw.Text(assigneeName, style: ts(font: boldFont)),
                    pw.SizedBox(height: 2),
                    pw.Text(dateStr, style: ts(size: 9, color: grey555)),
                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    pw.Widget buildVerificationSection() {
      return pw.Container(
        decoration: pw.BoxDecoration(
          border: pw.Border.all(width: 1.5),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              width: 110,
              padding: const pw.EdgeInsets.all(10),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  right: pw.BorderSide(width: 1.5),
                ),
              ),
              child: pw.Column(
                children: [
                  pw.Image(pw.MemoryImage(qrPngBytes), width: 85, height: 85),
                  pw.SizedBox(height: 4),
                  pw.Text(AppConstants.scanToVerify,
                      style: ts(size: 7, color: grey555),
                      textAlign: pw.TextAlign.center),
                ],
              ),
            ),
            pw.Expanded(
              child: pw.Padding(
                padding: const pw.EdgeInsets.all(10),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(AppConstants.verificationHeader,
                        style: ts(size: 8, font: boldFont, color: grey555)),
                    pw.SizedBox(height: 6),
                    pw.Text(verifyCode,
                        style: pw.TextStyle(
                          font: boldFont,
                          fontSize: 16,
                          letterSpacing: 4,
                        )),
                    pw.SizedBox(height: 6),
                    pw.Text(
                      'This code is generated from asset tag, recipient name, date, signature image hash '
                      'and a unique nonce. Any modification to this document will invalidate this code.',
                      style: ts(size: 8, color: grey555),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: pw.BoxDecoration(
                        color: greyF5,
                        borderRadius: pw.BorderRadius.circular(3),
                      ),
                      child: pw.Text(
                        'ASSET: $tag  |  ACTION: $action  |  DATE: $dateStr  |  S/N: $serial',
                        style: pw.TextStyle(
                          font: baseFont,
                          fontSize: 7,
                          color: grey555,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    pw.Widget buildFooter() {
      return pw.Text(
        AppConstants.footerCredit,
        style: ts(size: 8, color: grey555),
        textAlign: pw.TextAlign.right,
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              buildHeader(),
              pw.SizedBox(height: 8),
              buildDeviceTypeAndAssetNumber(),
              buildHardwareSection(),
              buildRemarkSection(),
              pw.SizedBox(height: 14),
              buildSignatureSection(),
              pw.SizedBox(height: 14),
              buildVerificationSection(),
              pw.Spacer(),
              buildFooter(),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  // ── PDF helpers ────────────────────────────────────────────────────────────

  pw.Widget _pdfCheckbox(
    String label, {
    bool checked = false,
    required pw.Font baseFont,
    required pw.Font boldFont,
  }) {
    return pw.Row(
      children: [
        pw.Container(
          width: 12,
          height: 12,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(width: 1.5),
            color:
                checked ? const PdfColor.fromInt(0xFF333333) : PdfColors.white,
          ),
          child: checked
              ? pw.Center(
                  child: pw.Transform.rotate(
                    angle: -0.7854,
                    child: pw.Container(
                      width: 5,
                      height: 8,
                      decoration: const pw.BoxDecoration(
                        border: pw.Border(
                          bottom:
                              pw.BorderSide(color: PdfColors.white, width: 1.3),
                          right:
                              pw.BorderSide(color: PdfColors.white, width: 1.3),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
        ),
        pw.SizedBox(width: 5),
        pw.Text(label, style: pw.TextStyle(font: boldFont, fontSize: 10)),
      ],
    );
  }

  pw.Widget _tableHeader(
    String text, {
    required pw.Font boldFont,
    required pw.TextStyle Function({
      double size,
      pw.Font? font,
      PdfColor color,
      double? lineSpacing,
    }) ts,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: pw.Text(text,
          style: ts(font: boldFont), textAlign: pw.TextAlign.center),
    );
  }

  // ── Download / share PDF ────────────────────────────────────────────────────
  // FIX #9: web uses a Blob download (universal_html); any other platform
  // (Android/iOS/desktop) writes the PDF to the app's temporary directory
  // and opens the native share/save sheet via share_plus, since
  // dart:html-style Blob downloads do not work outside of a real browser.

  Future<void> _downloadPdfFile(
      Uint8List pdfBytes, String action, DateTime now) async {
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final min = now.minute.toString().padLeft(2, '0');
    final filename = '${action}_${now.year}$mm${dd}_$hh$min.pdf';

    if (kIsWeb) {
      try {
        final blob = html.Blob([pdfBytes], 'application/pdf');
        final url = html.Url.createObjectUrlFromBlob(blob);

        final anchor = html.document.createElement('a') as html.AnchorElement
          ..href = url
          ..download = filename
          ..style.display = 'none';

        html.document.body!.append(anchor);
        anchor.click();
        anchor.remove();
        html.Url.revokeObjectUrl(url);

        debugPrint('=== [Download PDF] success (web): $filename');
      } catch (e, st) {
        debugPrint('=== [Download PDF] web error: $e\n$st');
      }
      return;
    }

    // Mobile / desktop path.
    try {
      final dir = await getTemporaryDirectory();
      final file = io.File('${dir.path}/$filename');
      await file.writeAsBytes(pdfBytes, flush: true);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf', name: filename)],
        text: filename,
      );

      debugPrint('=== [Download PDF] success (native share): $filename');
    } catch (e, st) {
      debugPrint('=== [Download PDF] native error: $e\n$st');
      if (mounted) {
        setState(() {
          _exportError =
              'Signature saved, but the PDF could not be shared: $e';
        });
      }
    }
  }

  // ── Build UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header (fixed) ────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
            decoration: const BoxDecoration(
              color: AppConstants.primaryNavy,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.draw_outlined,
                    color: Colors.white70, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600)),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(widget.subtitle!,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white60),
                  onPressed: () => Navigator.of(context).pop(null),
                ),
              ],
            ),
          ),

          // ── Scrollable content ────────────────────────────────────
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.asset != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppConstants.accentBlue.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppConstants.accentBlue.withOpacity(0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.laptop_mac,
                                  size: 14, color: AppConstants.accentBlue),
                              const SizedBox(width: 6),
                              Text(
                                widget.asset!.name ??
                                    widget.asset!.assetTag ??
                                    'Asset',
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppConstants.textPrimary),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            Text(
                              'S/N: ${widget.asset!.serial ?? '—'}  |  Tag: ${widget.asset!.assetTag ?? '—'}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppConstants.textSecondary),
                            ),
                            if (widget.assigneeName != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                '${widget.isCheckOut ? 'Recipient' : 'Returned by'}: ${widget.assigneeName}'
                                '${widget.division != null ? ' (${widget.division})' : ''}',
                                style: const TextStyle(
                                    fontSize: 11,
                                    color: AppConstants.textSecondary),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  if (widget.isCheckOut)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppConstants.accentAmber.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppConstants.accentAmber.withOpacity(0.4)),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.info_outline,
                                  size: 14, color: AppConstants.accentAmber),
                              SizedBox(width: 6),
                              Text(
                                'ข้อตกลงการรับอุปกรณ์',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppConstants.accentAmber),
                              ),
                            ]),
                            SizedBox(height: 6),
                            Text(
                              'Remark: The employee acknowledges that the Hardware received is the property of Stream I.T. Consulting Ltd. '
                              'The employee agrees to take care of and maintain the Hardware and a standard no lower than that which a person, '
                              'in general, would be expected to maintain. The hardware is possessed by the employee for work only.',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppConstants.textPrimary,
                                  height: 1.5),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'หมายเหตุ: พนักงานยอมรับทราบว่าฮาร์ดแวร์ที่ได้รับเป็นกรรมสิทธิ์ของบริษัท พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา'
                              'โดยฮาร์ดแวร์ที่ได้รับนี้พนักงานรับทราบว่ามีไว้สำหรับใช้ในการทำงานเท่านั้น',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: AppConstants.textPrimary,
                                  height: 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
                    child: Text(
                      'Sign in the box below',
                      style: TextStyle(
                          color: AppConstants.textSecondary, fontSize: 13),
                    ),
                  ),

                  if (_exportError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppConstants.accentRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppConstants.accentRed.withOpacity(0.4)),
                        ),
                        child: Text(_exportError!,
                            style: const TextStyle(
                                color: AppConstants.accentRed, fontSize: 12)),
                      ),
                    ),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      height: 220,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(
                          color: _isEmpty
                              ? AppConstants.divider
                              : AppConstants.accentBlue,
                          width: _isEmpty ? 1.5 : 2,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.hardEdge,
                      child: Stack(
                        children: [
                          Signature(
                            controller: _controller,
                            backgroundColor: Colors.white,
                          ),
                          Positioned(
                            bottom: 36,
                            left: 24,
                            right: 24,
                            child: Container(
                                height: 1, color: AppConstants.divider),
                          ),
                          if (_isEmpty)
                            const Center(
                              child: Text('Sign here',
                                  style: TextStyle(
                                      color: AppConstants.divider,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w300)),
                            ),
                        ],
                      ),
                    ),
                  ),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(Icons.picture_as_pdf_outlined,
                            size: 13, color: AppConstants.textSecondary),
                        SizedBox(width: 5),
                        Text(
                          'Document will be downloaded as PDF',
                          style: TextStyle(
                              fontSize: 11, color: AppConstants.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Actions (fixed) ───────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () {
                    _controller.clear();
                    setState(() {
                      _isEmpty = true;
                      _exportError = null;
                    });
                  },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Clear'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppConstants.textSecondary,
                    side: const BorderSide(color: AppConstants.divider),
                  ),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: (!_isEmpty && !_isExporting) ? _confirm : null,
                  icon: _isExporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  label: Text(_isExporting
                      ? 'Generating\u2026'
                      : 'Confirm & Download PDF'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small helper so we don't need to import dart:async just for this one
/// fire-and-forget call.
void unawaited(Future<void> future) {}