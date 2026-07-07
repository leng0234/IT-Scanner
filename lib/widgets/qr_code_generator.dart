import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

import 'pdf_layout_constants.dart';

/// Renders [data] as a QR code and returns PNG bytes via a `dart:ui` canvas.
///
/// Kept separate from the dialog/PDF-builder code since it has no
/// dependency on either — it's a pure "string in, PNG bytes out" utility,
/// which makes it easy to unit test or reuse (e.g. asset-detail screens
/// that also want a QR export) on its own.
Future<Uint8List> generateQrPngBytes(String data) async {
  final qr = QrCode.fromData(
    data: data,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final qrImage = QrImage(qr);
  final moduleCount = qr.moduleCount;
  const cellSize = PdfLayoutConstants.qrCellSize;
  const padding = PdfLayoutConstants.qrPadding;
  final totalSize = moduleCount * cellSize + padding * 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, totalSize.toDouble(), totalSize.toDouble()),
    Paint()..color = Colors.white,
  );
  final paint = Paint()..color = Colors.black;
  for (var row = 0; row < moduleCount; row++) {
    for (var col = 0; col < moduleCount; col++) {
      if (qrImage.isDark(row, col)) {
        canvas.drawRect(
          Rect.fromLTWH(
            (col * cellSize + padding).toDouble(),
            (row * cellSize + padding).toDouble(),
            cellSize.toDouble(),
            cellSize.toDouble(),
          ),
          paint,
        );
      }
    }
  }
  final picture = recorder.endRecording();
  final img = await picture.toImage(totalSize, totalSize);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}
