// Compiled once: the clipboard write path and the receive path both use these.
final _nonContentBlock = RegExp(
  r'<(script|style|head)\b[^>]*>.*?</\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final _htmlTag = RegExp('<[^>]*>');
final _namedEntity = RegExp('&(amp|lt|gt|quot|apos|nbsp|#39);');

const _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  '#39': "'",
  'nbsp': ' ',
};

/// Readable text for an HTML clip.
///
/// Drops markup, and the contents of script/style/head blocks along with it,
/// then decodes the handful of entities a browser actually emits on copy. It
/// is not an HTML renderer: it exists so an HTML clip reads as text in places
/// that cannot show markup - the plain-text clipboard fallback, the Obsidian
/// vault, the webhook - the same way the sending device's own plain-text
/// flavour does.
String htmlToPlainText(String html) => html
    .replaceAll(_nonContentBlock, '')
    .replaceAll(_htmlTag, '')
    .replaceAllMapped(_namedEntity, (m) => _entities[m[1]!]!)
    .trim();
