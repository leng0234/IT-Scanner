import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:signature/signature.dart';
import 'package:universal_html/html.dart' as html;

import '../models/asset_model.dart';
import '../utils/app_constants.dart';

/// แสดง dialog เซ็นชื่อ แล้ว generate PDF A4 สำหรับดาวน์โหลด
/// Returns PNG bytes ของลายเซ็น หรือ Uint8List(0) ถ้า Skip หรือ null ถ้ายกเลิก
Future<Uint8List?> showSignatureDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  AssetModel? asset,
  String? assigneeName,
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
      isCheckOut: isCheckOut,
    ),
  );
}

class _SignatureDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final AssetModel? asset;
  final String? assigneeName;
  final bool isCheckOut;

  const _SignatureDialog({
    required this.title,
    this.subtitle,
    this.asset,
    this.assigneeName,
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
          _exportError = 'ไม่สามารถบันทึกลายเซ็นได้ กรุณาลองใหม่';
        });
        return;
      }

      // Generate และ download PDF
      if (widget.asset != null) {
        await _generateAndDownloadPdf(pngBytes);
      }

      if (mounted) Navigator.of(context).pop(pngBytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _exportError = 'เกิดข้อผิดพลาด: $e';
        });
      }
    }
  }

  Future<void> _generateAndDownloadPdf(Uint8List sigBytes) async {
    final now = DateTime.now();
    final dateStr =
        '${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2, '0')} น.';
    final asset = widget.asset!;
    final action = widget.isCheckOut ? 'เบิกอุปกรณ์' : 'คืนอุปกรณ์';
    final sigBase64 = _bytesToBase64(sigBytes);

    final html = _buildHtml(
      action: action,
      dateStr: dateStr,
      asset: asset,
      assigneeName: widget.assigneeName ?? '—',
      sigBase64: sigBase64,
    );

    // Download HTML as file (ใช้ได้บน Web + Mobile)
    _downloadHtmlFile(html, action, now);
  }

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

  String _buildHtml({
    required String action,
    required String dateStr,
    required AssetModel asset,
    required String assigneeName,
    required String sigBase64,
  }) {
    final tag = asset.assetTag ?? '—';
    final serial = asset.serial ?? '—';
    final name = asset.name ?? asset.model?.name ?? '—';
    final manufacturer = asset.manufacturer?.name ?? '—';
    final model = asset.model?.name ?? '—';
    final status = asset.statusLabel?.name ?? '—';
    final isCheckOut = widget.isCheckOut;

    return '''<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$action — $tag</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Sarabun:wght@400;500;600;700&display=swap');
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Sarabun', sans-serif;
    font-size: 14px;
    color: #0D1B2A;
    background: #fff;
    padding: 40px;
    max-width: 794px;
    margin: 0 auto;
  }
  /* ── Header ── */
  .header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    border-bottom: 3px solid #0D1B2A;
    padding-bottom: 16px;
    margin-bottom: 24px;
  }
  .header-left h1 {
    font-size: 22px;
    font-weight: 700;
    letter-spacing: 0.5px;
  }
  .header-left .subtitle {
    font-size: 13px;
    color: #607080;
    margin-top: 4px;
  }
  .badge {
    display: inline-block;
    padding: 6px 16px;
    border-radius: 6px;
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 0.5px;
    color: #fff;
    background: ${isCheckOut ? '#1A73E8' : '#00C48C'};
  }
  /* ── Section ── */
  .section {
    margin-bottom: 20px;
  }
  .section-title {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 1.5px;
    text-transform: uppercase;
    color: #607080;
    margin-bottom: 10px;
    padding-bottom: 4px;
    border-bottom: 1px solid #E0E6EF;
  }
  /* ── Info grid ── */
  .info-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0;
    border: 1px solid #E0E6EF;
    border-radius: 8px;
    overflow: hidden;
  }
  .info-row {
    display: contents;
  }
  .info-label {
    background: #F5F7FA;
    padding: 9px 14px;
    font-size: 12px;
    color: #607080;
    font-weight: 600;
    border-bottom: 1px solid #E0E6EF;
  }
  .info-value {
    background: #fff;
    padding: 9px 14px;
    font-size: 13px;
    font-weight: 500;
    border-bottom: 1px solid #E0E6EF;
    border-left: 1px solid #E0E6EF;
  }
  .info-row:last-child .info-label,
  .info-row:last-child .info-value {
    border-bottom: none;
  }
  /* ── EULA ── */
  .eula-box {
    border: 1px solid #E0E6EF;
    border-radius: 8px;
    padding: 14px 16px;
    background: #F5F7FA;
    font-size: 12.5px;
    line-height: 1.8;
    color: #0D1B2A;
  }
  .eula-box p { margin-bottom: 6px; }
  .eula-box p:last-child { margin-bottom: 0; }
  /* ── Signature ── */
  .sig-section {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
    margin-top: 4px;
  }
  .sig-box {
    border: 1px solid #E0E6EF;
    border-radius: 8px;
    overflow: hidden;
  }
  .sig-box-label {
    background: #F5F7FA;
    padding: 7px 14px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.8px;
    color: #607080;
    text-transform: uppercase;
  }
  .sig-box-content {
    padding: 10px 14px;
    min-height: 90px;
    background: #fff;
  }
  .sig-box-content img {
    max-width: 100%;
    max-height: 80px;
    display: block;
  }
  .sig-name {
    font-size: 13px;
    font-weight: 600;
    margin-top: 6px;
    border-top: 1px solid #E0E6EF;
    padding-top: 6px;
    color: #0D1B2A;
  }
  .sig-date {
    font-size: 11px;
    color: #607080;
    margin-top: 2px;
  }
  /* ── Footer ── */
  .footer {
    margin-top: 24px;
    padding-top: 12px;
    border-top: 1px solid #E0E6EF;
    display: flex;
    justify-content: space-between;
    font-size: 11px;
    color: #607080;
  }
  @media print {
    body { padding: 20px; }
    .no-print { display: none; }
  }
</style>
</head>
<body>

<!-- ── Header ─────────────────────────────────────────── -->
<div class="header">
  <div class="header-left">
    <h1>แบบฟอร์ม${isCheckOut ? 'เบิก' : 'คืน'}อุปกรณ์</h1>
    <div class="subtitle">มหาวิทยาลัยเทคโนโลยีพระจอมเกล้าพระนครเหนือ (KMUTNB) — กองเทคโนโลยีสารสนเทศ</div>
  </div>
  <span class="badge">$action</span>
</div>

<!-- ── รายละเอียดอุปกรณ์ ─────────────────────────────── -->
<div class="section">
  <div class="section-title">รายละเอียดอุปกรณ์</div>
  <div class="info-grid">
    <div class="info-row">
      <div class="info-label">Asset Tag</div>
      <div class="info-value">$tag</div>
    </div>
    <div class="info-row">
      <div class="info-label">ชื่ออุปกรณ์</div>
      <div class="info-value">$name</div>
    </div>
    <div class="info-row">
      <div class="info-label">ยี่ห้อ</div>
      <div class="info-value">$manufacturer</div>
    </div>
    <div class="info-row">
      <div class="info-label">รุ่น</div>
      <div class="info-value">$model</div>
    </div>
    <div class="info-row">
      <div class="info-label">Serial Number</div>
      <div class="info-value">$serial</div>
    </div>
    <div class="info-row">
      <div class="info-label">สถานะ</div>
      <div class="info-value">$status</div>
    </div>
  </div>
</div>

<!-- ── รายละเอียดการ${isCheckOut ? 'เบิก' : 'คืน'} ──── -->
<div class="section">
  <div class="section-title">รายละเอียดการ${isCheckOut ? 'เบิก' : 'คืน'}</div>
  <div class="info-grid">
    <div class="info-row">
      <div class="info-label">${isCheckOut ? 'ผู้รับอุปกรณ์' : 'ผู้คืนอุปกรณ์'}</div>
      <div class="info-value">$assigneeName</div>
    </div>
    <div class="info-row">
      <div class="info-label">วันที่และเวลา</div>
      <div class="info-value">$dateStr</div>
    </div>
  </div>
</div>

<!-- ── ข้อตกลงการใช้งาน (EULA) ──────────────────────── -->
<div class="section">
  <div class="section-title">ข้อตกลงและเงื่อนไขการใช้อุปกรณ์</div>
  <div class="eula-box">
    <p><strong>1. การใช้งาน:</strong> ผู้รับอุปกรณ์ตกลงใช้อุปกรณ์เพื่อวัตถุประสงค์ของมหาวิทยาลัยเท่านั้น ห้ามใช้เพื่อประโยชน์ส่วนตัวหรือกิจกรรมที่ผิดกฎหมาย</p>
    <p><strong>2. การดูแลรักษา:</strong> ผู้รับอุปกรณ์มีหน้าที่ดูแลรักษาอุปกรณ์ให้อยู่ในสภาพดี และต้องแจ้งทันทีหากอุปกรณ์ชำรุดหรือสูญหาย</p>
    <p><strong>3. การรักษาความปลอดภัย:</strong> ห้ามติดตั้งซอฟต์แวร์ที่ไม่ได้รับอนุญาต และต้องปฏิบัติตามนโยบายความปลอดภัยสารสนเทศของมหาวิทยาลัย</p>
    <p><strong>4. ความรับผิดชอบ:</strong> หากอุปกรณ์เสียหายหรือสูญหายอันเกิดจากความประมาทเลินเล่อ ผู้รับอุปกรณ์ต้องรับผิดชอบค่าใช้จ่ายในการซ่อมหรือเปลี่ยนทดแทน</p>
    <p><strong>5. การคืนอุปกรณ์:</strong> ต้องคืนอุปกรณ์พร้อมอุปกรณ์เสริมครบถ้วนตามที่ระบุ เมื่อสิ้นสุดระยะเวลาการใช้งานหรือเมื่อได้รับการร้องขอ</p>
  </div>
</div>

<!-- ── ลายเซ็น ─────────────────────────────────────── -->
<div class="section">
  <div class="section-title">ลายเซ็นยืนยัน</div>
  <div class="sig-section">
    <div class="sig-box">
      <div class="sig-box-label">${isCheckOut ? 'ลายเซ็นผู้รับอุปกรณ์' : 'ลายเซ็นผู้คืนอุปกรณ์'}</div>
      <div class="sig-box-content">
        <img src="data:image/png;base64,$sigBase64" alt="signature">
        <div class="sig-name">$assigneeName</div>
        <div class="sig-date">วันที่: $dateStr</div>
      </div>
    </div>
    <div class="sig-box">
      <div class="sig-box-label">ลายเซ็นผู้มอบ / เจ้าหน้าที่</div>
      <div class="sig-box-content">
        <div style="height:60px;border-bottom:1px solid #E0E6EF;"></div>
        <div class="sig-name">ชื่อ: .........................................</div>
        <div class="sig-date">วันที่: .........................................</div>
      </div>
    </div>
  </div>
</div>

<!-- ── Footer ─────────────────────────────────────────── -->
<div class="footer">
  <span>เอกสารนี้สร้างโดยระบบ IT Asset Manager — KMUTNB</span>
  <span>$dateStr</span>
</div>

<!-- ── Print button (ไม่แสดงตอน print) ────────────────── -->
<div class="no-print" style="margin-top:24px;text-align:center;">
  <button onclick="window.print()" style="
    padding:10px 32px;
    background:#1A73E8;
    color:#fff;
    border:none;
    border-radius:8px;
    font-size:15px;
    font-family:'Sarabun',sans-serif;
    font-weight:600;
    cursor:pointer;
    margin-right:12px;
  ">🖨️ พิมพ์ / Save as PDF</button>
  <button onclick="window.close()" style="
    padding:10px 24px;
    background:#fff;
    color:#607080;
    border:1px solid #E0E6EF;
    border-radius:8px;
    font-size:15px;
    font-family:'Sarabun',sans-serif;
    cursor:pointer;
  ">ปิด</button>
</div>

</body>
</html>''';
  }

  void _downloadHtmlFile(String htmlContent, String action, DateTime now) {
    try {
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final min = now.minute.toString().padLeft(2, '0');
      final filename = '${action}_${now.year}$mm${dd}_$hh$min.html';

      // ใช้ universal_html สำหรับ Web download
      final bytes = htmlContent.codeUnits;
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


  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────
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

          // ── Info ─────────────────────────────────────────────────────────
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
                          fontSize: 11, color: AppConstants.textSecondary),
                    ),
                    if (widget.assigneeName != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${widget.isCheckOut ? 'ผู้รับ' : 'ผู้คืน'}: ${widget.assigneeName}',
                        style: const TextStyle(
                            fontSize: 11, color: AppConstants.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
            ),

          // ── Instruction ──────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 6),
            child: Text(
              'เซ็นชื่อในกล่องด้านล่าง',
              style: TextStyle(
                  color: AppConstants.textSecondary, fontSize: 13),
            ),
          ),

          // ── Error banner ─────────────────────────────────────────────────
          if (_exportError != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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

          // ── Signature canvas ─────────────────────────────────────────────
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
                      child: Text('เซ็นชื่อที่นี่',
                          style: TextStyle(
                              color: AppConstants.divider,
                              fontSize: 16,
                              fontWeight: FontWeight.w300)),
                    ),
                ],
              ),
            ),
          ),

          // ── Note ─────────────────────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Icon(Icons.download_outlined,
                    size: 13, color: AppConstants.textSecondary),
                SizedBox(width: 5),
                Text(
                  'กด "ยืนยัน" เพื่อดาวน์โหลดเอกสาร PDF A4',
                  style: TextStyle(
                      fontSize: 11, color: AppConstants.textSecondary),
                ),
              ],
            ),
          ),

          // ── Actions ───────────────────────────────────────────────────────
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
                  label: const Text('ล้าง'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppConstants.textSecondary,
                    side: const BorderSide(color: AppConstants.divider),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _isExporting
                      ? null
                      : () => Navigator.of(context).pop(Uint8List(0)),
                  child: const Text('ข้าม',
                      style:
                          TextStyle(color: AppConstants.textSecondary)),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: (!_isEmpty && !_isExporting) ? _confirm : null,
                  icon: _isExporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_outlined, size: 18),
                  label: Text(
                      _isExporting ? 'กำลังสร้างเอกสาร…' : 'ยืนยัน & ดาวน์โหลด'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}