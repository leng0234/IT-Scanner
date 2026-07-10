import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
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
///
/// Whichever path produces the bytes, the result is then post-processed
/// (see [_shrinkForStorage]) to cut down its size before it gets
/// base64-encoded and embedded in Snipe-IT's `notes` field: the raw
/// export is a full-canvas white PNG with a thin scribble in it, which
/// wastes most of its bytes on blank space and unnecessary resolution.
class SignatureExportUtils {
  SignatureExportUtils._();

  /// Signatures are only ever shown small (a row in a printed PDF table),
  /// so there's no benefit to keeping more horizontal resolution than
  /// this once the blank canvas margin has been cropped away.
  static const int _maxOutputWidth = 400;

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

    if (pngBytes == null || pngBytes.isEmpty) return pngBytes;

    // Whatever path produced the raw PNG, shrink it before it's handed
    // back to the caller (and eventually base64-embedded in Snipe-IT's
    // notes field). If shrinking fails for any reason, fall back to the
    // original bytes rather than losing the signature entirely.
    try {
      final shrunk = _shrinkForStorage(pngBytes);
      if (shrunk != null && shrunk.isNotEmpty) {
        debugPrint('=== [Signature] shrunk PNG: ${pngBytes.length} -> '
            '${shrunk.length} bytes');
        return shrunk;
      }
    } catch (e, st) {
      debugPrint('=== [Signature] shrinkForStorage failed, using '
          'original bytes: $e\n$st');
    }

    return pngBytes;
  }

  /// Crops away the blank white/transparent margin around the drawn
  /// strokes, downsamples to [_maxOutputWidth] if the cropped result is
  /// still wider than that, and re-encodes at maximum PNG compression.
  ///
  /// Returns null if the image can't be decoded or turns out to be
  /// entirely blank (nothing found to crop to) — the caller keeps the
  /// original bytes in that case.
  static Uint8List? _shrinkForStorage(Uint8List rawPngBytes) {
    final decoded = img.decodePng(rawPngBytes);
    if (decoded == null) return null;

    final cropped = _cropToContent(decoded);
    if (cropped == null) return null;

    final resized = cropped.width > _maxOutputWidth
        ? img.copyResize(
            cropped,
            width: _maxOutputWidth,
            interpolation: img.Interpolation.average,
          )
        : cropped;

    return Uint8List.fromList(img.encodePng(resized, level: 9));
  }

  /// Finds the bounding box of every non-blank pixel (i.e. not white and
  /// not fully transparent) and crops to it with a small padding margin.
  /// Returns null if no non-blank pixel is found.
  static img.Image? _cropToContent(img.Image src) {
    const blankThreshold = 245; // treat near-white as blank too
    const padding = 10;

    int minX = src.width;
    int minY = src.height;
    int maxX = -1;
    int maxY = -1;

    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final pixel = src.getPixel(x, y);
        final isBlank = pixel.a == 0 ||
            (pixel.r >= blankThreshold &&
                pixel.g >= blankThreshold &&
                pixel.b >= blankThreshold);
        if (isBlank) continue;

        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    if (maxX < 0 || maxY < 0) return null; // nothing drawn — all blank

    final x = (minX - padding).clamp(0, src.width - 1);
    final y = (minY - padding).clamp(0, src.height - 1);
    final w = (maxX - minX + padding * 2 + 1).clamp(1, src.width - x);
    final h = (maxY - minY + padding * 2 + 1).clamp(1, src.height - y);

    return img.copyCrop(src, x: x, y: y, width: w, height: h);
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
    final uiImage = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }
}