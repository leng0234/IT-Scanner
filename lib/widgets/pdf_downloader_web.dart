import 'dart:html' as html;
import 'dart:typed_data';

/// Web implementation: triggers a browser Blob download.
Future<void> downloadOrSharePdf(Uint8List pdfBytes, String filename) async {
  final blob = html.Blob([pdfBytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);

  final anchor = html.document.createElement('a') as html.AnchorElement
    ..href = url
    ..download = filename
    ..style.display = 'none';

  html.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}