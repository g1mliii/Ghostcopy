import 'dart:io';
import 'dart:typed_data';

export 'impl/clipboard_service.dart';

/// Clipboard content wrapper supporting text, HTML, images, and files
class ClipboardContent {
  const ClipboardContent._({
    this.text,
    this.html,
    this.imageBytes,
    this.fileBytes,
    this.filename,
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

  /// Create file clipboard content
  factory ClipboardContent.file(
    Uint8List bytes,
    String filename, [
    String? mimeType,
  ]) {
    return ClipboardContent._(
      fileBytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
  }

  final String? text;
  final String? html;
  final Uint8List? imageBytes;
  final Uint8List? fileBytes;
  final String? filename;
  final String? mimeType;

  bool get hasText => text != null && text!.isNotEmpty;
  bool get hasHtml => html != null && html!.isNotEmpty;
  bool get hasImage => imageBytes != null && imageBytes!.isNotEmpty;
  bool get hasFile => fileBytes != null && fileBytes!.isNotEmpty;
  bool get isEmpty => !hasText && !hasHtml && !hasImage && !hasFile;

  @override
  String toString() {
    if (hasFile) {
      return 'ClipboardContent(file: $filename, ${fileBytes!.length} bytes, $mimeType)';
    }
    if (hasImage) {
      return 'ClipboardContent(image: ${imageBytes!.length} bytes, $mimeType)';
    }
    if (hasHtml) return 'ClipboardContent(html: ${html!.length} chars)';
    if (hasText) return 'ClipboardContent(text: ${text!.length} chars)';
    return 'ClipboardContent(empty)';
  }
}

/// Abstract interface for clipboard operations
abstract class IClipboardService {
  /// Read clipboard content (file, image, HTML, or text)
  ///
  /// Priority: File > Image > HTML > Text
  /// Returns ClipboardContent with available formats
  Future<ClipboardContent> read();

  /// Write plain text to clipboard
  Future<void> writeText(String text);

  /// Write HTML to clipboard (with plain text fallback)
  Future<void> writeHtml(String html);

  /// Write image to clipboard
  Future<void> writeImage(Uint8List bytes);

  /// Write file path to clipboard (Windows/macOS file URI)
  ///
  /// Note: This writes the file path, not the file content
  /// Used for auto-receive to copy downloaded files
  Future<void> writeFilePath(String filePath);

  /// Write bytes to a temporary file and return the file
  /// Used for sharing files/images via native share sheet
  Future<File> writeTempFile(Uint8List bytes, String filename);

  /// Clear the clipboard
  Future<void> clear();
}
