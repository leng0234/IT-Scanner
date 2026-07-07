import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:signature/signature.dart';

import '../../models/asset_model.dart';
import '../../utils/app_constants.dart';
import 'document_verification.dart';
import 'font_cache.dart';
import 'prior_checkout_record.dart';
import 'qr_code_generator.dart';
import 'signature_export_utils.dart';
import 'signature_pdf_builder.dart';
import 'snipeit_file_api.dart';

export 'prior_checkout_record.dart' show PriorCheckoutRecord;

/// Opens the signature-capture dialog and, once signed, generates the
/// "Assets Profile" checkout/checkin PDF and uploads it to Snipe-IT.
///
/// See `prior_checkout_record.dart` for how to pass in [priorCheckout]
/// manually if you already have the checkout record from another source;
/// otherwise it's looked up automatically from Snipe-IT on checkin.
Future<Uint8List?> showSignatureDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  AssetModel? asset,
  String? assigneeName,
  String? division,
  bool isCheckOut = true,
  PriorCheckoutRecord? priorCheckout,
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
      priorCheckout: priorCheckout,
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
  final PriorCheckoutRecord? priorCheckout;

  const _SignatureDialog({
    required this.title,
    this.subtitle,
    this.asset,
    this.assigneeName,
    this.division,
    this.isCheckOut = true,
    this.priorCheckout,
  });

  @override
  State<_SignatureDialog> createState() => _SignatureDialogState();
}

class _SignatureDialogState extends State<_SignatureDialog> {
  late final SignatureController _controller;
  bool _isEmpty = true;
  bool _isExporting = false;
  String? _exportError;

  static const _snipeItApi = SnipeItFileApi();
  static const _pdfBuilder = SignaturePdfBuilder();

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
    unawaited(FontCache.ensureLoaded());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ── Confirm ────────────────────────────────────────────────────────────────

  Future<void> _confirm() async {
    if (_controller.isEmpty) return;
    setState(() {
      _isExporting = true;
      _exportError = null;
    });

    try {
      final pngBytes = await SignatureExportUtils.exportPngBytes(
        _controller,
        penColor: AppConstants.primaryNavy,
      );

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
        await _generateAndUploadPdf(pngBytes);
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

  // ── Generate the PDF and upload it (+ related artifacts) to Snipe-IT ─────

  Future<void> _generateAndUploadPdf(Uint8List sigBytes) async {
    final now = DateTime.now();
    final dateStr =
        '${now.day}/${now.month}/${now.year} ${now.hour}:${now.minute.toString().padLeft(2, '0')}';

    final asset = widget.asset!;
    final action = widget.isCheckOut ? 'Checkout' : 'Checkin';

    // For a checkin, if the caller didn't already pass in a
    // PriorCheckoutRecord, try to auto-recover the checkout signature/info
    // we saved to Snipe-IT when this asset was checked out, so the
    // "Receive" box on this checkin PDF isn't blank.
    PriorCheckoutRecord? priorCheckout = widget.priorCheckout;
    if (!widget.isCheckOut && priorCheckout == null && asset.id != null) {
      priorCheckout = await _snipeItApi.fetchPriorCheckoutRecord(
        assetId: asset.id!,
        assigneeName: widget.assigneeName,
        division: widget.division,
      );
    }

    final verifyCode = DocumentVerification.generateVerificationCode(
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

    final qrPngBytes = await generateQrPngBytes(qrData);

    await FontCache.ensureLoaded();

    // Logo
    Uint8List? logoBytes;
    try {
      final data = await rootBundle.load('assets/stream_logoNew.png');
      logoBytes = data.buffer.asUint8List();
    } catch (e, st) {
      debugPrint('=== [PDF] Failed to load logo: $e\n$st');
    }

    final pdfBytes = await _pdfBuilder.build(
      action: action,
      dateStr: dateStr,
      asset: asset,
      assigneeName: widget.assigneeName ?? '—',
      division: widget.division ?? '—',
      sigBytes: sigBytes,
      qrPngBytes: qrPngBytes,
      isCheckOut: widget.isCheckOut,
      logoBytes: logoBytes,
      verifyCode: verifyCode,
      sarabunRegular: FontCache.sarabunRegular,
      sarabunBold: FontCache.sarabunBold,
      priorCheckout: priorCheckout,
    );

    // Upload PDF ไปยัง Snipe-IT
    try {
      await _snipeItApi.uploadPdf(
        pdfBytes: pdfBytes,
        action: action,
        asset: asset,
        assigneeName: widget.assigneeName,
      );

      debugPrint('=== [Upload PDF] success');

      // On a successful CHECKOUT, also stash just the signature PNG so a
      // future checkin of this same asset can pull it back automatically.
      // This is `await`-ed (not `unawaited`) so a checkin started moments
      // later can't race the upload and see it as "missing" — the upload
      // still swallows its own errors internally, so this never blocks a
      // successful checkout.
      if (widget.isCheckOut) {
        await _snipeItApi.uploadCheckoutSignature(
          sigBytes: sigBytes,
          asset: asset,
          dateStr: dateStr,
          assigneeName: widget.assigneeName,
          division: widget.division,
        );
      } else if (asset.id != null) {
        // On a successful CHECKIN, remove the checkout PDF and the
        // standalone checkout-signature PNG from this asset. This runs
        // only after the checkin PDF itself uploaded successfully, and
        // never blocks or fails the checkin if cleanup has trouble.
        await _snipeItApi.deleteCheckoutArtifacts(asset.id!);
      }
    } catch (e, st) {
      debugPrint('=== [Upload PDF] error: $e\n$st');

      if (mounted) {
        setState(() {
          _exportError = 'PDF upload failed: $e';
        });
      }

      rethrow;
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
                              'หมายเหตุ: พนักงานยอมรับทราบว่าฮาร์ดแวร์ที่ได้รับเป็นกรรมสิทธิ์ของบริษัท พนักงานตกลงที่จะดูแลและรักษาฮาร์ดแวร์'
                              'ให้มีมาตรฐานไม่ต่ำกว่าที่บุคคลทั่วไปควรจะรักษา โดยฮาร์ดแวร์ที่ได้รับนี้พนักงานรับทราบว่ามีไว้สำหรับใช้ในการทำงานเท่านั้น',
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

                  // Centered + width-constrained so the signature board on
                  // Web/Tablet doesn't stretch wider than its real
                  // proportions and skew the drawn signature.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 500),
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
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (!_isEmpty && !_isExporting) ? _confirm : null,
                    icon: _isExporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.picture_as_pdf_outlined, size: 18),
                    label: Text(
                      _isExporting ? 'Generating\u2026' : 'Confirm & Save',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
