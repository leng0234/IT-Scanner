import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';
import 'package:signature/signature.dart';
import 'package:universal_html/html.dart' as html;

import '../models/asset_model.dart';
import '../utils/app_constants.dart';

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
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── HTML entity decoder ────────────────────────────────────────────────────

  String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&#60;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#62;', '>')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&ldquo;', '\u201C')
        .replaceAll('&rdquo;', '\u201D')
        .replaceAll('&lsquo;', '\u2018')
        .replaceAll('&rsquo;', '\u2019')
        .replaceAll('&ndash;', '\u2013')
        .replaceAll('&mdash;', '\u2014');
  }

  // ── Export signature PNG ───────────────────────────────────────────────────

  Future<Uint8List?> _exportSignatureBytes() async {
    Uint8List? pngBytes;

    try {
      pngBytes = await _controller.toPngBytes(height: 300, width: 600);
    } catch (_) {}

    if (pngBytes == null || pngBytes.isEmpty) {
      try {
        final image = await _controller.toImage(height: 300, width: 600);
        if (image != null) {
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          pngBytes = byteData?.buffer.asUint8List();
        }
      } catch (_) {}
    }

    if (pngBytes == null || pngBytes.isEmpty) {
      try {
        const w = 600.0;
        const h = 300.0;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
        canvas.drawRect(
            Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
        final paint = Paint()
          ..color = AppConstants.primaryNavy
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.fill;
        for (final point in _controller.points) {
          if (point == null) continue;
          canvas.drawCircle(point.offset, 1.75, paint);
        }
        final picture = recorder.endRecording();
        final img = await picture.toImage(w.toInt(), h.toInt());
        final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
        pngBytes = byteData?.buffer.asUint8List();
      } catch (_) {}
    }

    return pngBytes;
  }

  // ── Verification helpers ───────────────────────────────────────────────────

  String _generateHash(String data) {
    final bytes = utf8.encode(data);
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _generateVerificationCode({
    required String assetTag,
    required String assigneeName,
    required String dateStr,
    required String action,
    required Uint8List sigBytes,
  }) {
    final sigFingerprint = sigBytes
        .take(32)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final payload = '$assetTag|$assigneeName|$dateStr|$action|$sigFingerprint';
    final hash = _generateHash(payload);
    final nameHash = _generateHash(assigneeName);
    return '${hash.substring(0, 4)}-${hash.substring(4, 8)}-'
            '${nameHash.substring(0, 4)}-${nameHash.substring(4, 8)}'
        .toUpperCase();
  }

  // ── QR PNG via dart:ui canvas ──────────────────────────────────────────────

  Future<Uint8List> _generateQrPngBytes(String data) async {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qr);
    final moduleCount = qr.moduleCount;
    const cellSize = 6;
    const padding = 12;
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

// ── Load font bytes from bundled asset ──────────────────────────────────────

  Future<pw.Font?> _loadFontAsset(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return pw.Font.ttf(data);
    } catch (_) {
      return null;
    }
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
        setState(() {
          _isExporting = false;
          _exportError = 'Cannot save signature. Please try again.';
        });
        return;
      }

      if (widget.asset != null) {
        await _generateAndDownloadPdf(pngBytes);
      }

      if (mounted) Navigator.of(context).pop(pngBytes);
    } catch (e) {
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

    final verifyCode = _generateVerificationCode(
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
    } catch (_) {}

// ── Load bundled Sarabun font (Thai + Latin support) ──────────────────
    final sarabunRegular =
        await _loadFontAsset('assets/fonts/Sarabun-Regular.ttf');
    final sarabunBold = await _loadFontAsset('assets/fonts/Sarabun-Bold.ttf');

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
      sarabunRegular: sarabunRegular,
      sarabunBold: sarabunBold,
    );

    _downloadPdfFile(pdfBytes, action, now);
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
    // ── Fix: decode HTML entities from custom field values ─────────────────
    String getField(String key) {
      final field = (asset.customFields ?? {})[key];
      if (field == null) return '—';
      final raw = field['value']?.toString() ?? '—';
      return _decodeHtmlEntities(raw);
    }

    final tag = asset.assetTag ?? '—';
    final serial = asset.serial ?? '—';
    final name = _decodeHtmlEntities(asset.name ?? asset.model?.name ?? '—');
    final manufacturer = _decodeHtmlEntities(asset.manufacturer?.name ?? '—');
    final model = _decodeHtmlEntities(asset.model?.name ?? '—');
    final ram = getField('RAM');
    final storageType = getField('Storage Type');
    final capacity = getField('Capacity');
    final monitor = getField('Monitor');
    final isCheckOut = widget.isCheckOut;

    // Colors
    const grey555 = PdfColor.fromInt(0xFF555555);
    const greyDDD = PdfColor.fromInt(0xFFDDDDDD);
    const greyF0 = PdfColor.fromInt(0xFFF0F0F0);
    const greyF5 = PdfColor.fromInt(0xFFF5F5F5);
    const white = PdfColors.white;
    const actionBlue = PdfColor.fromInt(0xFF1A73E8);
    const actionGreen = PdfColor.fromInt(0xFF00C48C);

    // ── Fonts ──────────────────────────────────────────────────────────────
    // Use Sarabun when available (Thai + Latin). Fall back to Helvetica only
    // for Latin-only content when Sarabun failed to load.
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

    // ── Field row helper ───────────────────────────────────────────────────
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

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // ── Header ──────────────────────────────────────────────
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  if (logoBytes != null)
                    pw.Image(pw.MemoryImage(logoBytes), height: 40)
                  else
                    pw.SizedBox(width: 60),
                  pw.Expanded(
                    child: pw.Column(
                      children: [
                        pw.Text('Stream I.T. Consulting Ltd.',
                            style: ts(size: 12, font: boldFont),
                            textAlign: pw.TextAlign.center),
                        pw.SizedBox(height: 2),
                        pw.Text('ASSETS PROFILE',
                            style: ts(size: 14, font: boldFont),
                            textAlign: pw.TextAlign.center),
                      ],
                    ),
                  ),
                  pw.Text('ASSET PROFILE REV : 04 (22/02/65)',
                      style: ts(size: 8, color: grey555)),
                ],
              ),

              pw.SizedBox(height: 8),

              // ── Device type checkboxes ───────────────────────────────
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: pw.BoxDecoration(
                  color: greyF0,
                  border: pw.Border.all(width: 1.5),
                ),
                child: pw.Row(
                  children: [
                    _pdfCheckbox('NoteBook',
                        checked: true, baseFont: baseFont, boldFont: boldFont),
                    pw.SizedBox(width: 20),
                    _pdfCheckbox('PC', baseFont: baseFont, boldFont: boldFont),
                    pw.SizedBox(width: 20),
                    _pdfCheckbox('Server',
                        baseFont: baseFont, boldFont: boldFont),
                  ],
                ),
              ),

              // ── Asset number ─────────────────────────────────────────
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

              // ── Details header ───────────────────────────────────────
              pw.Container(
                color: grey555,
                padding: const pw.EdgeInsets.symmetric(vertical: 5),
                child: pw.Text(
                  'Details of Hardware',
                  style: ts(size: 11, font: boldFont, color: white),
                  textAlign: pw.TextAlign.center,
                ),
              ),

              // ── Details body ─────────────────────────────────────────
              pw.Container(
                padding: const pw.EdgeInsets.fromLTRB(12, 8, 12, 12),
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    left: pw.BorderSide(width: 1.5),
                    right: pw.BorderSide(width: 1.5),
                    bottom: pw.BorderSide(width: 1.5),
                  ),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                  children: [
                    fieldRow('Brand Name :', manufacturer,
                        label2: 'Model :', value2: model, minW2: 40),
                    fieldRow('S/N :', serial,
                        label2: 'Name :', value2: name, minW2: 40),
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
                            child:
                                pw.Text('Action :', style: ts(font: boldFont)),
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

              // ── Remark ──────────────────────────────────────────────
              pw.Container(
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
                    // English remark
                    pw.RichText(
                      text: pw.TextSpan(
                        children: [
                          pw.TextSpan(
                              text: 'Remark: ',
                              style: ts(size: 9, font: boldFont)),
                          pw.TextSpan(
                            text:
                                'The employee acknowledges that the Hardware received is the property of '
                                'Stream I.T. Consulting Ltd. The employee agrees to take care of and maintain '
                                'the Hardware and a standard no lower than that which a person, in general, '
                                'would be expected to maintain. The hardware is possessed by the employee for work only.',
                            style: ts(size: 9),
                          ),
                        ],
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    // Thai remark — uses Sarabun which covers Thai Unicode
                    pw.RichText(
                      text: pw.TextSpan(
                        children: [
                          pw.TextSpan(
                              text:
                                  '\u0e2b\u0e21\u0e32\u0e22\u0e40\u0e2b\u0e15\u0e38: ',
                              style: ts(size: 9, font: boldFont)),
                          pw.TextSpan(
                            text:
                                '\u0e1e\u0e19\u0e31\u0e01\u0e07\u0e32\u0e19\u0e22\u0e2d\u0e21\u0e23\u0e31\u0e1a\u0e17\u0e23\u0e32\u0e1a\u0e27\u0e48\u0e32\u0e2e\u0e32\u0e23\u0e4c\u0e14\u0e41\u0e27\u0e23\u0e4c\u0e17\u0e35\u0e48\u0e44\u0e14\u0e49\u0e23\u0e31\u0e1a\u0e40\u0e1b\u0e47\u0e19\u0e01\u0e23\u0e23\u0e21\u0e2a\u0e34\u0e17\u0e18\u0e34\u0e4c\u0e02\u0e2d\u0e07\u0e1a\u0e23\u0e34\u0e29\u0e31\u0e17 '
                                '\u0e1e\u0e19\u0e31\u0e01\u0e07\u0e32\u0e19\u0e15\u0e01\u0e25\u0e07\u0e17\u0e35\u0e48\u0e08\u0e30\u0e14\u0e39\u0e41\u0e25\u0e41\u0e25\u0e30\u0e23\u0e31\u0e01\u0e29\u0e32\u0e2e\u0e32\u0e23\u0e4c\u0e14\u0e41\u0e27\u0e23\u0e4c\u0e43\u0e2b\u0e49\u0e21\u0e35\u0e21\u0e32\u0e15\u0e23\u0e10\u0e32\u0e19\u0e44\u0e21\u0e48\u0e15\u0e48\u0e33\u0e01\u0e27\u0e48\u0e32\u0e17\u0e35\u0e48\u0e1a\u0e38\u0e04\u0e04\u0e25\u0e17\u0e31\u0e48\u0e27\u0e44\u0e1b\u0e04\u0e27\u0e23\u0e08\u0e30\u0e23\u0e31\u0e01\u0e29\u0e32 '
                                '\u0e42\u0e14\u0e22\u0e2e\u0e32\u0e23\u0e4c\u0e14\u0e41\u0e27\u0e23\u0e4c\u0e17\u0e35\u0e48\u0e44\u0e14\u0e49\u0e23\u0e31\u0e1a\u0e19\u0e35\u0e49\u0e1e\u0e19\u0e31\u0e01\u0e07\u0e32\u0e19\u0e23\u0e31\u0e1a\u0e17\u0e23\u0e32\u0e1a\u0e27\u0e48\u0e32\u0e21\u0e35\u0e44\u0e27\u0e49\u0e2a\u0e33\u0e2b\u0e23\u0e31\u0e1a\u0e43\u0e0a\u0e49\u0e43\u0e19\u0e01\u0e32\u0e23\u0e17\u0e33\u0e07\u0e32\u0e19\u0e40\u0e17\u0e48\u0e32\u0e19\u0e31\u0e49\u0e19',
                            style: ts(size: 9),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 14),

              // ── Signature table ──────────────────────────────────────
              pw.Table(
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
                            pw.Image(pw.MemoryImage(sigBytes), height: 55),
                            pw.Divider(
                                color: PdfColors.grey300, thickness: 0.5),
                            pw.Text(assigneeName, style: ts(font: boldFont)),
                            pw.SizedBox(height: 2),
                            pw.Text(dateStr,
                                style: ts(size: 9, color: grey555)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              pw.SizedBox(height: 14),

              // ── Verification box ─────────────────────────────────────
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(width: 1.5),
                ),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    // QR
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
                          pw.Image(pw.MemoryImage(qrPngBytes),
                              width: 85, height: 85),
                          pw.SizedBox(height: 4),
                          pw.Text('Scan to verify',
                              style: ts(size: 7, color: grey555),
                              textAlign: pw.TextAlign.center),
                        ],
                      ),
                    ),
                    // Info
                    pw.Expanded(
                      child: pw.Padding(
                        padding: const pw.EdgeInsets.all(10),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text('DOCUMENT VERIFICATION',
                                style: ts(
                                    size: 8, font: boldFont, color: grey555)),
                            pw.SizedBox(height: 6),
                            pw.Text(verifyCode,
                                style: pw.TextStyle(
                                  font: pw.Font.courier(),
                                  fontSize: 16,
                                  fontWeight: pw.FontWeight.bold,
                                  letterSpacing: 4,
                                )),
                            pw.SizedBox(height: 6),
                            pw.Text(
                              'This code is generated from asset tag, recipient name, date and signature fingerprint. '
                              'Any modification to this document will invalidate this code.',
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
                                  font: pw.Font.courier(),
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
              ),

              pw.Spacer(),

              // ── Footer ──────────────────────────────────────────────
              pw.Text(
                'Generated by IT Asset Manager — Stream I.T. Consulting Ltd.',
                style: ts(size: 8, color: grey555),
                textAlign: pw.TextAlign.right,
              ),
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

  // ── Download PDF ───────────────────────────────────────────────────────────

  void _downloadPdfFile(Uint8List pdfBytes, String action, DateTime now) {
    try {
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final min = now.minute.toString().padLeft(2, '0');
      final filename = '${action}_${now.year}$mm${dd}_$hh$min.pdf';

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

      debugPrint('=== [Download PDF] success: $filename');
    } catch (e) {
      debugPrint('=== [Download PDF] error: $e');
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
                  // ── Asset info ──────────────────────────────────
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
                  // ── Remark (checkout only) ──────────────────────
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
                              'หมายเหตุ: พนักงานยอมรับทราบว่าฮาร์ดแวร์ที่ได้รับเป็นกรรมสิทธิ์ของบริษัท '
                              'พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา '
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

                  // ── Instruction ─────────────────────────────────
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
                    child: Text(
                      'Sign in the box below',
                      style: TextStyle(
                          color: AppConstants.textSecondary, fontSize: 13),
                    ),
                  ),

                  // ── Error banner ────────────────────────────────
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

                  // ── Signature canvas ────────────────────────────
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

                  // ── Note ───────────────────────────────────────
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
