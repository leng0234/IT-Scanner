import 'dart:typed_data';

import '../../models/asset_model.dart';
// Platform-specific PDF download/share implementation.
// - Native (Android/iOS/desktop) builds resolve to pdf_downloader_native.dart
//   (path_provider + share_plus)
// - Anything else falls back to pdf_downloader_stub.dart
//
// Splitting this out (instead of importing dart:io / path_provider /
// share_plus directly behind a runtime platform check) is required because
// the Dart compiler still has to be able to *resolve* every import, even
// ones guarded by a runtime check.
//
// NOTE: add these to pubspec.yaml if not already present:
//   path_provider: ^2.1.0
//   share_plus: ^9.0.0
//
// NOTE: only stub (default) and native (dart:io) implementations exist in
// this project — there's no web build target, so the dart.library.html
// conditional import is left out.
import 'pdf_downloader_stub.dart'
    if (dart.library.io) '../pdf_downloader_native.dart';

/// Builds a safe, descriptive filename for the generated PDF and hands it
/// off to the platform-specific download/share implementation.
class PdfFilenameUtils {
  PdfFilenameUtils._();

  static String sanitize(String input) {
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'[^\w\u0E00-\u0E7F]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleaned.isEmpty ? 'Unknown' : cleaned;
  }

  static String buildFilename({
    required String action,
    required DateTime now,
    required AssetModel asset,
    required String assigneeName,
  }) {
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final yyyy = now.year.toString();

    final tag = sanitize(asset.assetTag ?? 'Unknown');
    final user = sanitize(assigneeName);
    final actionLabel = action.toLowerCase();

    return '${tag}_${user}_$yyyy$mm${dd}_$actionLabel.pdf';
  }

  static Future<void> downloadPdfFile({
    required Uint8List pdfBytes,
    required String action,
    required DateTime now,
    required AssetModel asset,
    required String assigneeName,
  }) async {
    final filename =
        buildFilename(action: action, now: now, asset: asset, assigneeName: assigneeName);
    await downloadOrSharePdf(pdfBytes, filename);
  }
}