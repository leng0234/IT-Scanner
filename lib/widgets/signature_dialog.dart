import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        final byteData =
            await img.toByteData(format: ui.ImageByteFormat.png);
        pngBytes = byteData?.buffer.asUint8List();
      } catch (_) {}
    }

    return pngBytes;
  }

  // ── Verification helpers ───────────────────────────────────────────────────

  /// FNV-1a 32-bit hash (JS-safe)
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

    final payload =
        '$assetTag|$assigneeName|$dateStr|$action|$sigFingerprint';
    final hash = _generateHash(payload);

    final nameHash = _generateHash(assigneeName);
    return '${hash.substring(0, 4)}-${hash.substring(4, 8)}-'
            '${nameHash.substring(0, 4)}-${nameHash.substring(4, 8)}'
        .toUpperCase();
  }

  /// Generate QR SVG from string data (uses package qr)
  String _generateQrSvg(String data) {
    final qr = QrCode.fromData(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qr);
    final size = qr.moduleCount;
    const cellSize = 4;
    const padding = 8;
    final svgSize = size * cellSize + padding * 2;

    final sb = StringBuffer();
    sb.write(
        '<svg xmlns="http://www.w3.org/2000/svg" width="$svgSize" height="$svgSize">');
    sb.write('<rect width="$svgSize" height="$svgSize" fill="white"/>');

    for (var row = 0; row < size; row++) {
      for (var col = 0; col < size; col++) {
        if (qrImage.isDark(row, col)) {
          final x = col * cellSize + padding;
          final y = row * cellSize + padding;
          sb.write(
              '<rect x="$x" y="$y" width="$cellSize" height="$cellSize" fill="black"/>');
        }
      }
    }
    sb.write('</svg>');
    return sb.toString();
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
        await _generateAndDownloadHtml(pngBytes);
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

  // ── Generate & download HTML ───────────────────────────────────────────────

  Future<void> _generateAndDownloadHtml(Uint8List sigBytes) async {
    final now = DateTime.now();
    final dateStr =
        '${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';
    final asset = widget.asset!;
    final action = widget.isCheckOut ? 'Checkout' : 'Checkin';
    final sigBase64 = _bytesToBase64(sigBytes);

    // Generate verification code
    final verifyCode = _generateVerificationCode(
      assetTag: asset.assetTag ?? '—',
      assigneeName: widget.assigneeName ?? '—',
      dateStr: dateStr,
      action: action,
      sigBytes: sigBytes,
    );

    // QR data
    final qrData = [
      'ASSET:${asset.assetTag ?? '—'}',
      'ACTION:$action',
      'RECIPIENT:${widget.assigneeName ?? '—'}',
      'DIVISION:${widget.division ?? '—'}',
      'DATE:$dateStr',
      'SERIAL:${asset.serial ?? '—'}',
      'VERIFY:$verifyCode',
    ].join('\n');

    final qrSvg = _generateQrSvg(qrData);
    final qrBase64 = base64.encode(utf8.encode(qrSvg));

    // Load logo from assets
    String logoBase64 = '';
    try {
      final logoBytes = await rootBundle.load('assets/stream_logoNew.png');
      logoBase64 = _bytesToBase64(logoBytes.buffer.asUint8List());
    } catch (_) {}

    final htmlContent = _buildHtml(
      action: action,
      dateStr: dateStr,
      asset: asset,
      assigneeName: widget.assigneeName ?? '—',
      division: widget.division ?? '—',
      sigBase64: sigBase64,
      customFields: asset.customFields ?? {},
      logoBase64: logoBase64,
      verifyCode: verifyCode,
      qrBase64: qrBase64,
    );

    _downloadHtmlFile(htmlContent, action, now);
  }

  // ── Base64 encoder ─────────────────────────────────────────────────────────

  String _bytesToBase64(Uint8List bytes) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final result = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b0 = bytes[i++];
      final b1 = i < bytes.length ? bytes[i++] : 0;
      final b2 = i < bytes.length ? bytes[i++] : 0;
      result.write(chars[(b0 >> 2) & 0x3F]);
      result.write(chars[((b0 << 4) | (b1 >> 4)) & 0x3F]);
      result.write(chars[((b1 << 2) | (b2 >> 6)) & 0x3F]);
      result.write(chars[b2 & 0x3F]);
    }
    final s = result.toString();
    switch (bytes.length % 3) {
      case 1:
        return '${s.substring(0, s.length - 2)}==';
      case 2:
        return '${s.substring(0, s.length - 1)}=';
      default:
        return s;
    }
  }

  // ── Build HTML ─────────────────────────────────────────────────────────────

  String _buildHtml({
    required String action,
    required String dateStr,
    required AssetModel asset,
    required String assigneeName,
    required String division,
    required String sigBase64,
    Map<String, dynamic> customFields = const {},
    String logoBase64 = '',
    String verifyCode = '',
    String qrBase64 = '',
  }) {
    String getField(String key) {
      final field = customFields[key];
      if (field == null) return '—';
      return field['value']?.toString() ?? '—';
    }

    final tag = asset.assetTag ?? '—';
    final serial = asset.serial ?? '—';
    final name = asset.name ?? asset.model?.name ?? '—';
    final manufacturer = asset.manufacturer?.name ?? '—';
    final model = asset.model?.name ?? '—';
    final ram = getField('RAM');
    final storageType = getField('Storage Type');
    final capacity = getField('Capacity');
    final monitor = getField('Monitor');
    final isCheckOut = widget.isCheckOut;

    final logoTag = logoBase64.isNotEmpty
        ? '<img src="data:image/png;base64,$logoBase64" alt="Logo" style="height:52px;">'
        : '<div style="width:80px;"></div>';

    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Assets Profile — $tag</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Sarabun:wght@400;500;600;700&display=swap');
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Sarabun', sans-serif;
    font-size: 13px;
    color: #000;
    background: #fff;
    padding: 32px 40px;
    max-width: 794px;
    margin: 0 auto;
  }
  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }
  .header-center { text-align: center; flex: 1; padding: 0 16px; }
  .header-center .company { font-size: 15px; font-weight: 700; }
  .header-center .form-title {
    font-size: 17px; font-weight: 700;
    letter-spacing: 1px; margin-top: 2px;
  }
  .header-right { text-align: right; font-size: 11px; color: #555; }
  .type-row {
    display: flex; align-items: center; gap: 24px;
    border: 1.5px solid #000; border-bottom: none;
    padding: 6px 14px; background: #f0f0f0;
  }
  .type-row label {
    display: flex; align-items: center;
    gap: 6px; font-weight: 600; font-size: 13px;
  }
  .checkbox {
    width: 14px; height: 14px; border: 1.5px solid #000;
    display: inline-flex; align-items: center;
    justify-content: center; font-size: 11px; font-weight: 700;
  }
  .checked { background: #333; color: #fff; }
  .asset-bar {
    border: 1.5px solid #000; border-bottom: none;
    display: flex; align-items: center; padding: 5px 14px; gap: 12px;
  }
  .asset-bar .label { font-weight: 700; font-size: 13px; }
  .asset-bar .value { font-weight: 700; font-size: 15px; letter-spacing: 0.5px; }
  .details-header {
    background: #555; color: #fff; text-align: center;
    font-weight: 700; font-size: 14px; padding: 5px;
    border: 1.5px solid #000; border-bottom: none; letter-spacing: 0.5px;
  }
  .details-body { border: 1.5px solid #000; padding: 10px 14px 14px; }
  .field-row {
    display: flex; align-items: baseline;
    margin-bottom: 9px; gap: 8px;
  }
  .field-row:last-child { margin-bottom: 0; }
  .field-label { font-weight: 600; min-width: 110px; font-size: 13px; flex-shrink: 0; }
  .field-value {
    flex: 1; border-bottom: 1px solid #888;
    padding-bottom: 1px; font-size: 13px; min-width: 80px;
  }
  .remark {
    border: 1.5px solid #000; border-top: none;
    padding: 10px 14px; font-size: 12px; line-height: 1.7;
  }
  .sig-table { width: 100%; border-collapse: collapse; margin-top: 16px; }
  .sig-table th {
    background: #ddd; border: 1.5px solid #000;
    padding: 7px 12px; font-weight: 700; font-size: 13px; text-align: center;
  }
  .sig-table td {
    border: 1.5px solid #000; padding: 8px 12px;
    font-size: 13px; vertical-align: top;
  }
  .sig-img { max-height: 70px; max-width: 100%; display: block; }
  .sig-name { font-weight: 600; font-size: 13px; margin-top: 6px; border-top: 1px solid #ccc; padding-top: 4px; }
  .sig-date { font-size: 11px; color: #555; margin-top: 2px; }
  .verify-box {
    margin-top: 16px; border: 1.5px solid #000;
    display: flex; align-items: stretch;
  }
  .verify-qr {
    padding: 12px; border-right: 1.5px solid #000;
    display: flex; flex-direction: column;
    align-items: center; justify-content: center; min-width: 120px;
  }
  .verify-qr img { width: 90px; height: 90px; }
  .verify-qr-label { font-size: 9px; color: #555; margin-top: 4px; text-align: center; }
  .verify-info { padding: 12px; flex: 1; }
  .verify-title {
    font-size: 10px; font-weight: 700; letter-spacing: 1px;
    color: #555; margin-bottom: 8px; text-transform: uppercase;
  }
  .verify-code {
    font-family: monospace; font-size: 18px; font-weight: 700;
    letter-spacing: 4px; color: #000; margin-bottom: 8px;
  }
  .verify-desc { font-size: 11px; color: #555; line-height: 1.6; }
  .verify-meta {
    margin-top: 8px; padding: 6px 10px;
    background: #f5f5f5; border-radius: 4px;
    font-size: 10px; color: #333; font-family: monospace;
  }
  .footer {
    margin-top: 16px; font-size: 10px;
    color: #888; text-align: right;
  }
  @media print {
    body { padding: 16px 24px; }
    .no-print { display: none; }
  }
</style>
</head>
<body>

<!-- Header -->
<div class="header">
  <div>$logoTag</div>
  <div class="header-center">
    <div class="company">Stream I.T. Consulting Ltd.</div>
    <div class="form-title">ASSETS PROFILE</div>
  </div>
  <div class="header-right">ASSET PROFILE REV : 04 (22/02/65)</div>
</div>

<!-- Device type -->
<div class="type-row">
  <label><div class="checkbox checked">&#10003;</div> NoteBook</label>
  <label><div class="checkbox"></div> PC</label>
  <label><div class="checkbox"></div> Server</label>
</div>

<!-- Asset number -->
<div class="asset-bar">
  <span class="label">Asset Number :</span>
  <span class="value">$tag</span>
</div>

<!-- Details header -->
<div class="details-header">Details of Hardware</div>

<!-- Details body -->
<div class="details-body">
  <div class="field-row">
    <span class="field-label">Brand Name :</span>
    <span class="field-value">$manufacturer</span>
    <span class="field-label" style="min-width:55px;">Model :</span>
    <span class="field-value">$model</span>
  </div>
  <div class="field-row">
    <span class="field-label">S/N :</span>
    <span class="field-value">$serial</span>
    <span class="field-label" style="min-width:55px;">Name :</span>
    <span class="field-value">$name</span>
  </div>
  <div class="field-row">
    <span class="field-label">Harddisk :</span>
    <span class="field-value">$storageType $capacity</span>
    <span class="field-label" style="min-width:55px;">RAM :</span>
    <span class="field-value">$ram</span>
  </div>
  <div class="field-row">
    <span class="field-label">Monitor :</span>
    <span class="field-value">$monitor</span>
  </div>
  <div class="field-row">
    <span class="field-label">Action :</span>
    <span class="field-value" style="font-weight:600;color:${isCheckOut ? '#1A73E8' : '#00C48C'};">$action</span>
    <span class="field-label" style="min-width:55px;">Date :</span>
    <span class="field-value">$dateStr</span>
  </div>
</div>

<!-- Remark -->
<div class="remark">
  <strong>Remark:</strong> The employee acknowledges that the Hardware received is the property of Stream I.T. Consulting Ltd.
  The employee agrees to take care of and maintain the Hardware and a standard no lower than that which a person,
  in general, would be expected to maintain. The hardware is possessed by the employee for work only.<br>
  <strong>หมายเหตุ:</strong> พนักงานยอมรับทราบว่าฮาร์ดแวร์ที่ได้รับเป็นกรรมสิทธิ์ของบริษัท พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา
  โดยฮาร์ดแวร์ที่ได้รับนี้พนักงานรับทราบว่ามีไว้สำหรับใช้ในการทำงานเท่านั้น
</div>

<!-- Signature table -->
<table class="sig-table">
  <thead>
    <tr>
      <th>Name</th>
      <th>Division</th>
      <th>Received Date / Signature</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td style="min-width:160px;">
        <div style="padding-top:4px; font-weight:600;">$assigneeName</div>
      </td>
      <td style="min-width:100px;">
        <div style="padding-top:4px;">$division</div>
      </td>
      <td style="min-width:220px;">
        <img class="sig-img" src="data:image/png;base64,$sigBase64" alt="signature">
        <div class="sig-name">$assigneeName</div>
        <div class="sig-date">$dateStr</div>
      </td>
    </tr>
  </tbody>
</table>

<!-- Verification -->
<div class="verify-box">
  <div class="verify-qr">
    <img src="data:image/svg+xml;base64,$qrBase64" alt="QR">
    <div class="verify-qr-label">Scan to verify</div>
  </div>
  <div class="verify-info">
    <div class="verify-title">Document Verification</div>
    <div class="verify-code">$verifyCode</div>
    <div class="verify-desc">
      This code is generated from asset tag, recipient name, date and signature fingerprint.<br>
      Any modification to this document will invalidate this code.
    </div>
    <div class="verify-meta">
      ASSET: $tag &nbsp;|&nbsp; ACTION: $action &nbsp;|&nbsp; DATE: $dateStr &nbsp;|&nbsp; S/N: $serial
    </div>
  </div>
</div>

<div class="footer">Generated by IT Asset Manager — Stream I.T. Consulting Ltd.</div>

<!-- Print button -->
<div class="no-print" style="margin-top:20px; text-align:center;">
  <button onclick="window.print()" style="
    padding:10px 32px; background:#1A73E8; color:#fff;
    border:none; border-radius:8px; font-size:14px;
    font-family:'Sarabun',sans-serif; font-weight:600;
    cursor:pointer; margin-right:12px;">
    Print / Save as PDF
  </button>
  <button onclick="window.close()" style="
    padding:10px 24px; background:#fff; color:#607080;
    border:1px solid #ccc; border-radius:8px; font-size:14px;
    font-family:'Sarabun',sans-serif; cursor:pointer;">
    Close
  </button>
</div>

</body>
</html>''';
  }

  // ── Download HTML file ─────────────────────────────────────────────────────

  void _downloadHtmlFile(String htmlContent, String action, DateTime now) {
    try {
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final min = now.minute.toString().padLeft(2, '0');
      final filename = '${action}_${now.year}$mm${dd}_$hh$min.html';

      final bytes = utf8.encode(htmlContent);
      final blob = html.Blob(
        [Uint8List.fromList(bytes)],
        'text/html;charset=utf-8',
      );
      final url = html.Url.createObjectUrlFromBlob(blob);

      final anchor = html.document.createElement('a') as html.AnchorElement
        ..href = url
        ..download = filename
        ..style.display = 'none';

      html.document.body!.append(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);

      debugPrint('=== [Download] success: $filename');
    } catch (e) {
      debugPrint('=== [Download] error: $e');
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
          // ── Header (fixed) ──────────────────────────────────────────────
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

          // ── Scrollable content ──────────────────────────────────────────
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Asset info ──────────────────────────────────────────
                  if (widget.asset != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppConstants.accentBlue.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color:
                                  AppConstants.accentBlue.withOpacity(0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              const Icon(Icons.laptop_mac,
                                  size: 14,
                                  color: AppConstants.accentBlue),
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

                  // ── Remark / ข้อตกลง (checkout only) ────────────────────
                  if (widget.isCheckOut)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color:
                              AppConstants.accentAmber.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppConstants.accentAmber
                                  .withOpacity(0.4)),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(Icons.info_outline,
                                  size: 14,
                                  color: AppConstants.accentAmber),
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
                              'พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา'
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

                  // ── Instruction ─────────────────────────────────────────
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
                    child: Text(
                      'Sign in the box below',
                      style: TextStyle(
                          color: AppConstants.textSecondary, fontSize: 13),
                    ),
                  ),

                  // ── Error banner ────────────────────────────────────────
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
                              color:
                                  AppConstants.accentRed.withOpacity(0.4)),
                        ),
                        child: Text(_exportError!,
                            style: const TextStyle(
                                color: AppConstants.accentRed,
                                fontSize: 12)),
                      ),
                    ),

                  // ── Signature canvas ────────────────────────────────────
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
                                height: 1,
                                color: AppConstants.divider),
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

                  // ── Note ────────────────────────────────────────────────
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(Icons.verified_outlined,
                            size: 13,
                            color: AppConstants.textSecondary),
                        SizedBox(width: 5),
                        Text(
                          'Document includes QR code & verification code',
                          style: TextStyle(
                              fontSize: 11,
                              color: AppConstants.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Actions (fixed) ─────────────────────────────────────────────
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
                  onPressed:
                      (!_isEmpty && !_isExporting) ? _confirm : null,
                  icon: _isExporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: Text(_isExporting
                      ? 'Generating…'
                      : 'Confirm & Download'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}