import 'dart:typed_data';

export 'impl/clipboard_service.dart';

/// Clipboard content wrapper supporting text, HTML, and images
class ClipboardContent {
  const ClipboardContent._({
    this.text,
    this.html,
    this.imageBytes,
    this.mimeType,
  });

  /// Create empty clipboard content
  const ClipboardContent.empty() : this._();

  /// Create text-only clipboard content
  factory ClipboardContent.text(String text) {
    return ClipboardContent._(text: text);
  }

  /// Create HTML clipboard content (with plain text fallback)
  factory ClipboardContent.html(String html) {
    return ClipboardContent._(html: html, text: html);
  }

  /// Create image clipboard content
  factory ClipboardContent.image(Uint8List bytes, String mimeType) {
    return ClipboardContent._(imageBytes: bytes, mimeType: mimeType);
  }

  final String? text;
  final String? html;
  final Uint8List? imageBytes;
  final String? mimeType;

  bool get hasText => text != null && text!.isNotEmpty;
  bool get hasHtml => html != null && html!.isNotEmpty;
  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
  bool get isEmpty => !hasText && !hasHtml && !hasImage;

  @override
  String toString() {
    if (hasImage) return 'ClipboardContent(image: ${imageBytes!.length} bytes, $mimeType)';
    if (hasHtml) return 'ClipboardContent(html: ${html!.length} chars)';
    if (hasText) return 'ClipboardContent(text: ${text!.length} chars)';
    return 'ClipboardContent(empty)';
  }
}

/// Abstract interface for clipboard operations
abstract class IClipboardService {
  /// Read clipboard content (text, HTML, or image)
  ///
  /// Priority: Image > HTML > Text
  /// Returns ClipboardContent with available formats
  Future<ClipboardContent> read();

  /// Write plain text to clipboard
  Future<void> writeText(String text);

  /// Write HTML to clipboard (with plain text fallback)
  Future<void> writeHtml(String html);

  /// Write image to clipboard
  Future<void> writeImage(Uint8List bytes);

  /// Clear the clipboard
  Future<void> clear();
}
