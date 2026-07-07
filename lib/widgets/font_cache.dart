import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart' as pw;

/// Font bytes are loaded once and cached at the class (static) level
/// instead of being re-read from the asset bundle on every single
/// checkout/checkin PDF generation.
///
/// `ensureLoaded()` is idempotent based on whether the fonts are already
/// populated, rather than a one-shot "attempted" flag — so if a load ever
/// fails (e.g. transient asset-bundle hiccup), the next call will retry
/// instead of being permanently stuck on `null` fonts for the rest of the
/// app's lifetime.
class FontCache {
  FontCache._();

  static pw.Font? sarabunRegular;
  static pw.Font? sarabunBold;

  static Future<void> ensureLoaded() async {
    if (sarabunRegular != null && sarabunBold != null) {
      return;
    }

    sarabunRegular = await _load('assets/fonts/Sarabun-Regular.ttf');
    sarabunBold = await _load('assets/fonts/Sarabun-Bold.ttf');
  }

  static Future<pw.Font?> _load(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return pw.Font.ttf(data);
    } catch (e, st) {
      debugPrint('=== [FontCache] Failed to load $assetPath: $e\n$st');
      return null;
    }
  }
}
