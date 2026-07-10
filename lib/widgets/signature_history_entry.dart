import 'dart:convert';
import 'dart:typed_data';

/// One signature capture event: either a "Checkout" or a "Checkin" for one
/// cycle of this asset's life.
///
/// [cycleId] is what ties a checkout and its matching checkin together —
/// both carry the same cycleId so they can be paired back up into a single
/// printable row later (see [SignatureHistoryRow]).
///
/// History is no longer stored as separate PNG files in Snipe-IT. Instead,
/// every entry (including its signature image, base64-encoded) is embedded
/// in the JSON `notes` field of the single "Assets Profile" PDF file kept
/// per asset — see `SnipeItFileApi.uploadPdf` / `fetchSignatureHistory`.
class SignatureHistoryEntry {
  final String cycleId;
  final String action; // 'Checkout' or 'Checkin'
  final String assigneeName;
  final String? division;
  final String dateStr;
  final Uint8List sigBytes;
  final int fileId;

  const SignatureHistoryEntry({
    required this.cycleId,
    required this.action,
    required this.assigneeName,
    this.division,
    required this.dateStr,
    required this.sigBytes,
    required this.fileId,
  });

  bool get isCheckout => action.toLowerCase() == 'checkout';

  /// Encodes this entry (including its signature image as base64) for
  /// embedding in the PDF file's `notes` field.
  Map<String, dynamic> toJson() => {
        'cycleId': cycleId,
        'action': action,
        'assigneeName': assigneeName,
        'division': division,
        'dateStr': dateStr,
        'sigBase64': base64Encode(sigBytes),
      };

  /// Rebuilds an entry from the JSON embedded in a PDF's `notes` field.
  /// [fileId] is meaningless here (no separate file backs this entry
  /// anymore) and is always 0.
  factory SignatureHistoryEntry.fromJson(Map<String, dynamic> json) {
    final sigBase64 = json['sigBase64']?.toString() ?? '';
    return SignatureHistoryEntry(
      cycleId: json['cycleId']?.toString() ?? 'unknown',
      action: json['action']?.toString() ?? 'Checkout',
      assigneeName: json['assigneeName']?.toString() ?? '—',
      division: json['division']?.toString(),
      dateStr: json['dateStr']?.toString() ?? '—',
      sigBytes: sigBase64.isEmpty ? Uint8List(0) : base64Decode(sigBase64),
      fileId: 0,
    );
  }
}

/// A checkout entry and its matching checkin entry (if the asset hasn't
/// been returned yet, [checkinEntry] is null) paired into one row for the
/// PDF's Name / Division / Receive / Return table.
class SignatureHistoryRow {
  final String cycleId;
  final SignatureHistoryEntry? checkoutEntry;
  final SignatureHistoryEntry? checkinEntry;

  const SignatureHistoryRow({
    required this.cycleId,
    this.checkoutEntry,
    this.checkinEntry,
  });

  String? get displayName =>
      checkoutEntry?.assigneeName ?? checkinEntry?.assigneeName;

  String? get displayDivision =>
      checkoutEntry?.division ?? checkinEntry?.division;
}