import 'package:html_unescape/html_unescape.dart';

/// Shared HTML-entity decoding helper.
///
/// Snipe-IT HTML-encodes custom field values and note text (e.g. `"`
/// becomes `&quot;`), so anything read back from the API needs this before
/// it's displayed or parsed as JSON.
class HtmlEntityUtils {
  HtmlEntityUtils._();

  static final HtmlUnescape _instance = HtmlUnescape();

  static String decode(String input) => _instance.convert(input);
}
