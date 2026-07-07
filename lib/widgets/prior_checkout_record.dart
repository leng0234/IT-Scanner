import 'dart:typed_data';

/// Snapshot of a *prior* checkout's signature/recipient info, so that when
/// generating a check**in** PDF, the checkout box on the same page can be
/// filled in instead of printing blank.
///
/// This is normally populated automatically by [SnipeItFileApi
/// .fetchPriorCheckoutRecord] (see `snipeit_file_api.dart`), which looks up
/// the checkout-signature file that was uploaded to Snipe-IT when the asset
/// was checked out. You can still construct one manually and pass it into
/// `showSignatureDialog(isCheckOut: false, priorCheckout: ...)` if you have
/// the data from another source, e.g.:
///
/// ```dart
/// final prior = PriorCheckoutRecord(
///   assigneeName: saved.assigneeName,
///   division: saved.division,
///   dateStr: saved.dateStr,
///   sigBytes: saved.signaturePngBytes,
/// );
/// ```
class PriorCheckoutRecord {
  final String assigneeName;
  final String? division;
  final String dateStr;
  final Uint8List sigBytes;

  const PriorCheckoutRecord({
    required this.assigneeName,
    this.division,
    required this.dateStr,
    required this.sigBytes,
  });
}
