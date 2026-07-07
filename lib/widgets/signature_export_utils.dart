import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';

/// Exports the drawn signature to PNG bytes, with two fallback strategies
/// in case the package-provided export methods fail.
///
/// Order of attempts:
/// 1. `SignatureController.toPngBytes()` — the normal path.
/// 2. `SignatureController.toImage()` — package-level fallback.
/// 3. A manual `dart:ui` canvas replay of the recorded points — last
///    resort, used if both package methods come back empty (seen on some
///    web/canvas edge cases).
///
/// The manual fallback computes its canvas size from the actual max X/Y of
/// the recorded points (instead of a fixed size), so the signature isn't
/// clipped or squashed to a fixed aspect ratio.
class SignatureExportUtils {
  SignatureExportUtils._();

  static Future<Uint8List?> exportPngBytes(
    SignatureController controller, {
    required Color penColor,
  }) async {
    Uint8List? pngBytes;

    try {
      pngBytes = await controller.toPngBytes();
    } catch (e, st) {
      debugPrint('=== [Signature] toPngBytes failed: $e\n$st');
    }

    if (pngBytes == null || pngBytes.isEmpty) {
      try {
        final image = await controller.toImage();
        if (image != null) {
          final byteData =
              await image.toByteData(format: ui.ImageByteFormat.png);
          pngBytes = byteData?.buffer.asUint8List();
        }
      } catch (e, st) {
        debugPrint('=== [Signature] toImage fallback failed: $e\n$st');
      }
    }

    if (pngBytes == null || pngBytes.isEmpty) {
      try {
        pngBytes = await _manualCanvasFallback(controller, penColor);
      } catch (e, st) {
        debugPrint('=== [Signature] manual canvas fallback failed: $e\n$st');
      }
    }

    return pngBytes;
  }

  static Future<Uint8List?> _manualCanvasFallback(
    SignatureController controller,
    Color penColor,
  ) async {
    double maxX = 0;
    double maxY = 0;
    for (final point in controller.points) {
      if (point != null) {
        if (point.offset.dx > maxX) maxX = point.offset.dx;
        if (point.offset.dy > maxY) maxY = point.offset.dy;
      }
    }

    final w = (maxX + 20).clamp(300.0, 2000.0);
    final h = (maxY + 20).clamp(220.0, 2000.0);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    final paint = Paint()
      ..color = penColor
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    Offset? previous;
    for (final point in controller.points) {
      if (point == null) {
        previous = null;
        continue;
      }
      if (previous != null) {
        canvas.drawLine(previous, point.offset, paint);
      } else {
        canvas.drawCircle(point.offset, 1.75, Paint()..color = penColor);
      }
      previous = point.offset;
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }
}
