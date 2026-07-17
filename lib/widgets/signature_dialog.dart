import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:signature/signature.dart';

import '../../models/asset_model.dart';
import '../../utils/app_constants.dart';
import 'font_cache.dart';
// import 'qr_code_generator.dart'; // QR disabled — see comments below
import 'signature_export_utils.dart';
import 'signature_history_entry.dart';
import 'signature_pdf_builder.dart';
import 'snipeit_file_api.dart';

export 'signature_history_entry.dart'
    show SignatureHistoryEntry, SignatureHistoryRow;

/// Opens the signature-capture dialog and, once signed, generates the
/// "Assets Profile" checkout/checkin PDF and uploads it to Snipe-IT.
///
/// The PDF's signature table always shows the asset's *full* checkout/
/// checkin history (every person who's ever had it). That history is no
/// longer stored as separate PNG files — it's embedded as JSON (including
/// every signature image, base64-encoded) in the `notes` field of the
/// single PDF file kept per asset. Every time a new PDF is generated, the
/// previous PDF's embedded history is read back out, merged with today's
/// signing event, and re-embedded in the new PDF before the old one is
/// deleted — see `signature_history_entry.dart` and
/// `SnipeItFileApi.fetchSignatureHistory` / `uploadPdf`.
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

    // A cycleId ties this checkout to its matching checkin so they print
    // as one row in the history table:
    // - Checkout: always mints a brand new cycleId (a new hand-off starts
    //   a new cycle, even if an older one was somehow left open).
    // - Checkin: reuses whatever open cycle is currently on record for
    //   this asset (the most recent checkout without a matching checkin
    //   yet). If none is found — e.g. this app wasn't used for the
    //   original checkout — a fresh cycleId is minted so the checkin still
    //   gets its own row instead of being dropped.
    String cycleId;
    if (widget.isCheckOut) {
      cycleId = 'C${now.millisecondsSinceEpoch}';
    } else {
      cycleId = (asset.id != null
              ? await _snipeItApi.findOpenCycleId(assetId: asset.id!)
              : null) ??
          'C${now.millisecondsSinceEpoch}';
    }

    await FontCache.ensureLoaded();

    // Logo
    Uint8List? logoBytes;
    try {
      final data = await rootBundle.load('assets/stream_logoNew.png');
      logoBytes = data.buffer.asUint8List();
    } catch (e, st) {
      debugPrint('=== [PDF] Failed to load logo: $e\n$st');
    }

    // Upload PDF ไปยัง Snipe-IT
    try {
      // Fetch the existing history (every cycle recorded on the current
      // *active* PDF, with signature images already embedded as base64)
      // *before* touching anything else, then merge in today's signing
      // event.
      final historyResult = asset.id != null
          ? await _snipeItApi.fetchSignatureHistory(assetId: asset.id!)
          : (rows: <SignatureHistoryRow>[], sourceFileId: null);
      final historyRowsBefore = historyResult.rows;
      final previousFileId = historyResult.sourceFileId;

      final newEntry = SignatureHistoryEntry(
        cycleId: cycleId,
        action: action,
        assigneeName: widget.assigneeName ?? '—',
        division: widget.division,
        dateStr: dateStr,
        sigBytes: sigBytes,
        fileId: 0,
      );

      // Merge the new entry into the existing rows (matching on cycleId),
      // then re-sort so the table stays chronological.
      final mergedRows = <String, SignatureHistoryRow>{
        for (final r in historyRowsBefore) r.cycleId: r,
      };
      final existingRow = mergedRows[cycleId];
      mergedRows[cycleId] = SignatureHistoryRow(
        cycleId: cycleId,
        checkoutEntry:
            newEntry.isCheckout ? newEntry : existingRow?.checkoutEntry,
        checkinEntry:
            newEntry.isCheckout ? existingRow?.checkinEntry : newEntry,
      );
      final orderedCycleIds = mergedRows.keys.toList()..sort();

      // Snipe-IT's `notes` field has a practical size limit, and every
      // cycle kept adds a base64-encoded signature image to it. Cap each
      // PDF to a fixed number of cycles — once merging today's event
      // would exceed that cap, leave the current PDF (with its full
      // history) untouched forever as an archive, and start a brand new
      // PDF/history containing only today's signing event. Over many
      // uses this produces a series of archived PDFs on the asset instead
      // of one ever-growing file — nothing is ever silently dropped.
      const maxHistoryCycles = 3;
      List<SignatureHistoryRow> historyRows;
      // `>` (not `>=`): a PDF keeps accumulating cycles up to and
      // including `maxHistoryCycles` — it's only once a cycle *beyond*
      // that would be merged in that a fresh PDF/history starts instead.
      // This is what lets an archived PDF end up holding the full
      // `maxHistoryCycles` cycles rather than one short of it. (Note-
      // stripping for a PDF that's reached the cap happens separately,
      // right below, as soon as every one of its cycles is closed — it
      // doesn't wait for this branch to fire.)
      final startingFreshArchive = orderedCycleIds.length > maxHistoryCycles;

      if (startingFreshArchive) {
        historyRows = [mergedRows[cycleId]!];
        debugPrint('=== [History] $maxHistoryCycles-cycle cap reached — '
            'archiving previous PDF (file $previousFileId) and starting '
            'a fresh history');
      } else {
        historyRows = [
          for (final id in orderedCycleIds) mergedRows[id]!,
        ];
      }

      // Flatten back to individual entries for embedding in the new PDF's
      // notes field.
      final flatHistoryEntries = <SignatureHistoryEntry>[
        for (final row in historyRows) ...[
          if (row.checkoutEntry != null) row.checkoutEntry!,
          if (row.checkinEntry != null) row.checkinEntry!,
        ],
      ];

      final pdfBytes = await _pdfBuilder.build(
        action: action,
        dateStr: dateStr,
        asset: asset,
        assigneeName: widget.assigneeName ?? '—',
        division: widget.division ?? '—',
        sigBytes: sigBytes,
        // qrPngBytes: qrPngBytes, // QR disabled — see comments above
        isCheckOut: widget.isCheckOut,
        logoBytes: logoBytes,
        sarabunRegular: FontCache.sarabunRegular,
        sarabunBold: FontCache.sarabunBold,
        historyRows: historyRows,
      );

      final uploadResult = await _snipeItApi.uploadPdf(
        pdfBytes: pdfBytes,
        action: action,
        asset: asset,
        assigneeName: widget.assigneeName,
        historyEntries: flatHistoryEntries,
      );

      debugPrint('=== [Upload PDF] success (file ${uploadResult.fileId})');

      // The previous version of the active file — the one whose history
      // this upload just continued — is always redundant now, whether or
      // not this upload also happens to have hit the cap: everything it
      // held has been folded into the PDF just uploaded.
      if (asset.id != null && !startingFreshArchive && previousFileId != null) {
        await _snipeItApi.deletePdfFile(
          assetId: asset.id!,
          fileId: previousFileId,
        );
      }

      // Has the PDF just uploaded reached the cap with every cycle fully
      // closed (no dangling checkout waiting on its checkin)? If so, it
      // will never be written to again — the next new cycle always
      // starts a fresh PDF — so its note (the JSON history blob, every
      // signature image included) is safe to strip right now instead of
      // lingering until that next PDF appears.
      final closedOutAtCap = !startingFreshArchive &&
          historyRows.length == maxHistoryCycles &&
          historyRows.every(
              (row) => row.checkoutEntry != null && row.checkinEntry != null);

      if (asset.id != null && closedOutAtCap && uploadResult.fileId != null) {
        debugPrint('=== [History] $maxHistoryCycles-cycle cap reached with '
            'every cycle closed — stripping note from file '
            '${uploadResult.fileId} now');
        await _snipeItApi.finalizeClosedCycleFile(
          assetId: asset.id!,
          fileId: uploadResult.fileId!,
          pdfBytes: pdfBytes,
          fileName: uploadResult.fileName,
        );
      } else if (asset.id != null &&
          startingFreshArchive &&
          previousFileId != null) {
        // Safety net: the cap was exceeded (a cycle beyond
        // maxHistoryCycles just came in), which normally means the old
        // file should already have had its note stripped by the
        // `closedOutAtCap` branch above in an earlier run. If that didn't
        // happen for some reason, catch it here via a fresh
        // download-and-reupload instead of leaving the note in place
        // forever.
        await _snipeItApi.clearArchivedFileNote(
          assetId: asset.id!,
          fileId: previousFileId,
        );
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
                              'Remark: The employee acknowledges that the Hardware received is the property of company. '
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