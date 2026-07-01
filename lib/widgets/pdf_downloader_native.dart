import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Native (Android/iOS/desktop) implementation: writes the PDF to the app's
/// temporary directory and opens the native share/save sheet.
Future<void> downloadOrSharePdf(Uint8List pdfBytes, String filename) async {
  final dir = await getTemporaryDirectory();
  final file = io.File('${dir.path}/$filename');
  await file.writeAsBytes(pdfBytes, flush: true);

  await Share.shareXFiles(
    [XFile(file.path, mimeType: 'application/pdf', name: filename)],
    text: filename,
  );
}