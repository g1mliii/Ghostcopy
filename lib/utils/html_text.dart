// Compiled once: the clipboard write path and the receive path both use these.
final _nonContentBlock = RegExp(
  r'<(script|style|head)\b[^>]*>.*?</\1\s*>',
  caseSensitive: false,
  dotAll: true,
);
final _htmlTag = RegExp('<[^>]*>');
// Where a browser would start a new line: <br>, and the end of a block.
final _lineBreak = RegExp(
  r'<br\s*/?>|</(?:p|div|li|h[1-6]|tr|blockquote|pre)\s*>',
  caseSensitive: false,
);
final _blankLines = RegExp(r'\n{3,}');
final _entity = RegExp(
  '&(?:(amp|lt|gt|quot|apos|nbsp)|#([0-9]+)|#[xX]([0-9a-fA-F]+));',
);

const _entities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
};

String _decodeEntity(Match m) {
  final named = m[1];
  if (named != null) return _entities[named]!;
  final code = m[2] != null
      ? int.tryParse(m[2]!)
      : int.tryParse(m[3]!, radix: 16);
  // Out of range, or a lone surrogate: leave the entity as it was.
  if (code == null || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) {
    return m[0]!;
  }
  return String.fromCharCode(code);
}

/// Readable text for an HTML clip.
///
/// Drops markup, and the contents of script/style/head blocks along with it,
/// keeps a line break where a paragraph, list item or <br> ended, then decodes
/// the named entities a browser emits on copy and any numeric one (`&#8217;`,
/// `&#x2019;`). It is not an HTML renderer: it exists so an HTML clip reads as
/// text in places that cannot show markup - the plain-text clipboard fallback,
/// the Obsidian vault, the webhook - the same way the sending device's own
/// plain-text flavour does.
String htmlToPlainText(String html) => html
    .replaceAll(_nonContentBlock, '')
    .replaceAll(_lineBreak, '\n')
    .replaceAll(_htmlTag, '')
    .replaceAllMapped(_entity, _decodeEntity)
    .replaceAll(_blankLines, '\n\n')
    .trim();
