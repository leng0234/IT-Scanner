import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/asset_model.dart';
import '../../utils/app_constants.dart';
import 'html_entity_utils.dart';
import 'signature_history_entry.dart';

/// Standalone typedef for avoiding inline nesting issues on some Dart
/// analyzers.
typedef PdfTextStyleBuilder = pw.TextStyle Function({
  double size,
  pw.Font? font,
  PdfColor color,
  double? lineSpacing,
});

/// Builds the single-page "Assets Profile" PDF document: header, device
/// type / asset number boxes, hardware details, remark section, the
/// checkout/checkin signature table, and the QR/verification footer.
///
/// Pulled out of the dialog widget so the page layout can be read and
/// tweaked in isolation from the signature-capture / upload orchestration
/// logic.
class SignaturePdfBuilder {
  const SignaturePdfBuilder();

  Future<Uint8List> build({
    required String action,
    required String dateStr,
    required AssetModel asset,
    required String assigneeName,
    required String division,
    required Uint8List sigBytes,
    // QR code disabled for now — see buildVerificationSection() below and
    // the generateQrPngBytes() call in signature_dialog.dart, both
    // commented out. This stays optional/unused until re-enabled.
    Uint8List? qrPngBytes,
    required bool isCheckOut,
    Uint8List? logoBytes,
    String verifyCode = '',
    pw.Font? sarabunRegular,
    pw.Font? sarabunBold,
    // Every checkout/checkin cycle this asset has ever had, oldest first.
    // The signature table renders one row per entry here. If this is
    // empty (e.g. history lookup failed or the asset has no id), a single
    // fallback row is built from the current action instead so the PDF
    // still shows at least today's signature.
    List<SignatureHistoryRow> historyRows = const [],
  }) async {
    String getField(String key) {
      final field = (asset.customFields ?? {})[key];
      if (field == null) return '—';
      final raw = field['value']?.toString() ?? '—';
      return HtmlEntityUtils.decode(raw);
    }

    final tag = asset.assetTag ?? '—';
    final serial = asset.serial ?? '—';
    final manufacturer =
        HtmlEntityUtils.decode(asset.manufacturer?.name ?? '—');
    final model = HtmlEntityUtils.decode(asset.model?.name ?? '—');
    final ram = getField('RAM');
    final storageType = getField('Storage Type');
    final capacity = getField('Capacity');
    final monitor = getField('Monitor');
    final monitorType = getField('Type');
    final monitorSerial = getField('S/N Monitor');
    final warrantyPeriod = getField('Warranty Period');
    final warrantyProvider = getField('Warranty Provider');
    final poNumber = getField('PO Number');
    final objectId = getField('Object ID');

    const grey555 = PdfColor.fromInt(0xFF555555);
    const greyDDD = PdfColor.fromInt(0xFFDDDDDD);
    const greyF0 = PdfColor.fromInt(0xFFF0F0F0);
    const greyF5 = PdfColor.fromInt(0xFFF5F5F5);
    const white = PdfColors.white;
    const accentNavyText = PdfColor.fromInt(0xFF1A3A6B);

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
      double minW2 = 68,
      bool underline1 = true,
      bool underline2 = true,
    }) {
      final children = <pw.Widget>[
        pw.SizedBox(
          width: minW1,
          child: pw.Text(label1, style: ts(font: boldFont)),
        ),
        pw.Expanded(
          child: pw.Container(
            decoration: underline1
                ? const pw.BoxDecoration(
                    border: pw.Border(
                      bottom: pw.BorderSide(color: PdfColors.grey, width: 0.5),
                    ),
                  )
                : null,
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
              decoration: underline2
                  ? const pw.BoxDecoration(
                      border: pw.Border(
                        bottom:
                            pw.BorderSide(color: PdfColors.grey, width: 0.5),
                      ),
                    )
                  : null,
              padding: const pw.EdgeInsets.only(bottom: 1),
              child: pw.Text(value2, style: ts()),
            ),
          ),
        ]);
      }
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 9),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: children,
        ),
      );
    }

    final doc = pw.Document();

    pw.Widget buildHeader() {
      // Fixed height so the Stack has a real, bounded size to center things
      // in — without this, the Stack's height is only as tall as the
      // center text block, so a taller logo just overflows past the
      // bottom of the header into the section below it.
      //
      // If you make the logo taller than this, bump headerHeight up to
      // match (roughly: logo height + a little breathing room).
      const headerHeight = 55.0;
      return pw.SizedBox(
        height: headerHeight,
        child: pw.Stack(
          children: [
            // ชื่อบริษัท/ชื่อฟอร์ม — กึ่งกลางเป๊ะของความกว้างทั้งหมด ไม่ขึ้นกับฝั่งซ้าย-ขวา
            pw.Center(
              child: pw.Column(
                mainAxisAlignment: pw.MainAxisAlignment.center,
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
            // โลโก้ — ชิดซ้าย จัดกึ่งกลางแนวตั้งของกรอบ header
            if (logoBytes != null)
              pw.Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Image(pw.MemoryImage(logoBytes), height: 60),
                ),
              ),
            // Revision label — ชิดขวาบนสุด
            pw.Positioned(
              right: 0,
              top: 0,
              child: pw.Text(AppConstants.formRevisionLabel,
                  style: ts(size: 8, color: grey555)),
            ),
          ],
        ),
      );
    }

    pw.Widget buildDeviceTypeAndAssetNumber() {
      // Device-type checkboxes and Asset Number sit side by side on the
      // same line, but remain two visually separate boxes (each keeps its
      // own border/background). Uses a Table instead of a Row so both
      // cells get the same height automatically (the `pdf` package has no
      // IntrinsicHeight / stretch-in-a-Row support the way Flutter does —
      // Table is the pattern already used successfully for the signature
      // grid further down this file).
      return pw.Table(
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
        columnWidths: const {
          0: pw.FlexColumnWidth(3),
          1: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(
            children: [
              // กล่องที่ 1: checkbox ประเภทอุปกรณ์
              pw.Container(
                alignment: pw.Alignment.centerLeft,
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
                        boldFont: boldFont,
                      ),
                    ],
                  ],
                ),
              ),
              // กล่องที่ 2: Asset Number (ยังคงแยกกล่อง มีขอบครบ 4 ด้านของตัวเอง)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8),
                child: pw.Container(
                  alignment: pw.Alignment.center,
                  padding: const pw.EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(width: 1.5),
                  ),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text('Asset Number:  ',
                          style: pw.TextStyle(
                            font: pw.Font.helveticaBoldOblique(),
                            fontSize: 12,
                            color: accentNavyText,
                          )),
                      pw.Text(tag,
                          style: pw.TextStyle(
                            font: pw.Font.helveticaBoldOblique(),
                            fontSize: 14,
                            color: accentNavyText,
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    pw.Widget buildHardwareSection() {
      return pw.Container(
        padding:
            const pw.EdgeInsets.all(0.75), // เผื่อพื้นที่ให้ border width 1.5
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
                      label2: 'Model :', value2: model),
                  fieldRow('S/N :', serial),
                  fieldRow('Harddisk :', '$storageType $capacity'.trim(),
                      label2: 'RAM :', value2: ram),
                  fieldRow('Monitor :', monitor),
                  fieldRow('S/N :', monitorSerial,
                      label2: 'Type :', value2: monitorType),
                  pw.SizedBox(height: 6),
                  fieldRow('Warranty :', warrantyPeriod, underline1: false),
                  fieldRow('Warranty :', warrantyProvider,
                      label2: 'Object ID :',
                      value2: objectId,
                      underline1: false,
                      underline2: false),
                  fieldRow('PO Number :', poNumber,
                      minW1: 80, underline1: false),
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
        decoration: pw.BoxDecoration(
          border: pw.Border.all(width: 1.5),
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
            pw.SizedBox(height: 6),
            pw.RichText(
              text: pw.TextSpan(
                children: [
                  pw.TextSpan(
                      text:
                          '\u0e2b\u0e21\u0e32\u0e22\u0e40\u0e2b\u0e15\u0e38: ',
                      style: ts(size: 9, font: boldFont, lineSpacing: 4)),
                  pw.TextSpan(
                    text: AppConstants.checkoutRemarkTh,
                    style: ts(size: 9, lineSpacing: 4),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    pw.Widget buildSignatureCell({
      required Uint8List? sigImageBytes,
      required String? date,
    }) {
      final hasSig = sigImageBytes != null;
      return pw.Container(
        height: 62,
        padding: const pw.EdgeInsets.all(4),
        child: pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.end,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: hasSig
                  ? pw.Align(
                      alignment: pw.Alignment.center,
                      child: pw.Image(
                        pw.MemoryImage(sigImageBytes),
                        height: 26,
                        fit: pw.BoxFit.contain,
                      ),
                    )
                  : pw.Center(
                      child: pw.Text('ยังไม่มีลายเซ็น',
                          style: ts(size: 6, color: PdfColors.grey400)),
                    ),
            ),
            pw.Divider(color: PdfColors.grey300, thickness: 0.5, height: 4),
            pw.Row(
              children: [
                pw.Text('Date  ', style: ts(size: 6, font: boldFont)),
                pw.Expanded(
                  child:
                      pw.Text(hasSig ? (date ?? '—') : '', style: ts(size: 6)),
                ),
              ],
            ),
          ],
        ),
      );
    }

    pw.Widget buildSignatureSection() {
      // Build one printable row per history entry — every checkout/checkin
      // cycle this asset has ever had. If no history could be loaded (e.g.
      // the asset has no id yet, or the Snipe-IT lookup failed), fall back
      // to a single row built from just today's action so the PDF still
      // shows at least the current signature.
      final baseRows = historyRows.isNotEmpty
          ? historyRows
          : [
              SignatureHistoryRow(
                cycleId: 'current',
                checkoutEntry: isCheckOut
                    ? SignatureHistoryEntry(
                        cycleId: 'current',
                        action: 'Checkout',
                        assigneeName: assigneeName,
                        division: division,
                        dateStr: dateStr,
                        sigBytes: sigBytes,
                        fileId: 0,
                      )
                    : null,
                checkinEntry: isCheckOut
                    ? null
                    : SignatureHistoryEntry(
                        cycleId: 'current',
                        action: 'Checkin',
                        assigneeName: assigneeName,
                        division: division,
                        dateStr: dateStr,
                        sigBytes: sigBytes,
                        fileId: 0,
                      ),
              ),
            ];

      // Always reserve a minimum number of printable rows on the
      // signature table, so the form comes out with blank rows ready for
      // future checkout/checkin cycles — no need to regenerate the PDF
      // just to add one more row later. Real history rows are always
      // shown in full; empty rows are only appended to pad the count up
      // to the minimum, never used to trim genuine history.
      const minSignatureRows = 3;
      final rows = <SignatureHistoryRow>[
        ...baseRows,
        for (var i = baseRows.length; i < minSignatureRows; i++)
          SignatureHistoryRow(
            cycleId: 'empty-$i',
            checkoutEntry: null,
            checkinEntry: null,
          ),
      ];

      pw.TableRow buildDataRow(SignatureHistoryRow row) {
        return pw.TableRow(
          children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.Align(
                alignment: pw.Alignment.topCenter,
                child: pw.Text(
                  row.displayName ?? '—',
                  style: ts(size: 8, font: boldFont),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            ),
            pw.Padding(
              padding: const pw.EdgeInsets.all(4),
              child: pw.Align(
                alignment: pw.Alignment.topCenter,
                child: pw.Text(
                  row.displayDivision ?? '—',
                  style: ts(size: 8),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            ),
            buildSignatureCell(
              sigImageBytes: row.checkoutEntry?.sigBytes,
              date: row.checkoutEntry?.dateStr,
            ),
            buildSignatureCell(
              sigImageBytes: row.checkinEntry?.sigBytes,
              date: row.checkinEntry?.dateStr,
            ),
          ],
        );
      }

      return pw.Table(
        border: pw.TableBorder.all(width: 1.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(2.2),
          1: const pw.FlexColumnWidth(1.3),
          2: const pw.FlexColumnWidth(2.5),
          3: const pw.FlexColumnWidth(2.5),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: greyDDD),
            children: [
              _tableHeader('Name', boldFont: boldFont, ts: ts),
              _tableHeader('Division', boldFont: boldFont, ts: ts),
              _tableHeader('Receive', boldFont: boldFont, ts: ts),
              _tableHeader('Return', boldFont: boldFont, ts: ts),
            ],
          ),
          for (final row in rows) buildDataRow(row),
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
            // QR code disabled — the qrPngBytes param above and the
            // generateQrPngBytes() call in signature_dialog.dart are
            // commented out too. Uncomment all three spots to bring it
            // back.
            //
            // pw.Container(
            //   width: 110,
            //   padding: const pw.EdgeInsets.all(10),
            //   decoration: const pw.BoxDecoration(
            //     border: pw.Border(
            //       right: pw.BorderSide(width: 1.5),
            //     ),
            //   ),
            //   child: pw.Column(
            //     children: [
            //       pw.Image(pw.MemoryImage(qrPngBytes!), width: 85, height: 85),
            //       pw.SizedBox(height: 4),
            //       pw.Text(AppConstants.scanToVerify,
            //           style: ts(size: 7, color: grey555),
            //           textAlign: pw.TextAlign.center),
            //     ],
            //   ),
            // ),
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
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        // Printed on every page (not just the last), which also gives a
        // natural "this document continues..." cue when the signature
        // history table spills onto page 2+.
        footer: (context) => buildFooter(),
        build: (context) => [
          buildHeader(),
          pw.SizedBox(height: 8),
          buildDeviceTypeAndAssetNumber(),
          pw.SizedBox(height: 8),
          buildHardwareSection(),
          pw.SizedBox(height: 8),
          buildRemarkSection(),
          pw.SizedBox(height: 14),
          // pw.Table implements SpanningWidget, so when there are enough
          // history rows to overflow the page, MultiPage automatically
          // continues it onto a new page instead of clipping it — unlike
          // the old pw.Page, which had no pagination at all.
          buildSignatureSection(),
          pw.SizedBox(height: 14),
          buildVerificationSection(),
        ],
      ),
    );

    return doc.save();
  }

  // ── PDF widget helpers ─────────────────────────────────────────────────────

  pw.Widget _pdfCheckbox(
    String label, {
    bool checked = false,
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
        ),
        pw.SizedBox(width: 5),
        pw.Text(label, style: pw.TextStyle(font: boldFont, fontSize: 10)),
      ],
    );
  }

  pw.Widget _tableHeader(
    String text, {
    required pw.Font boldFont,
    required PdfTextStyleBuilder ts,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: pw.Text(text,
          style: ts(size: 8, font: boldFont), textAlign: pw.TextAlign.center),
    );
  }
}
