import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../clipboard_service.dart';

/// Implementation of clipboard operations using super_clipboard
class ClipboardService implements IClipboardService {
  ClipboardService._();

  /// Singleton instance
  static final ClipboardService instance = ClipboardService._();

  @override
  Future<ClipboardContent> read() async {
    try {
      final reader = await SystemClipboard.instance?.read();
      if (reader == null) return const ClipboardContent.empty();

      // Try to read file URI first (highest priority for desktop)
      if (reader.canProvide(Formats.fileUri)) {
        debugPrint('[ClipboardService] ↓ Reading file URI');
        try {
          final fileUri = await reader.readValue(Formats.fileUri);
          if (fileUri != null) {
            final file = File(fileUri.toFilePath());
            if (file.existsSync()) {
              // ignore: avoid_slow_async_io - Large files need async to prevent UI freeze
              final bytes = await file.readAsBytes();
              final filename = path.basename(file.path);

              // Validate file size (10MB limit)
              if (bytes.length <= 10485760) {
                debugPrint(
                  '[ClipboardService] ✓ Read file: $filename (${bytes.length} bytes)',
                );
                return ClipboardContent.file(bytes, filename);
              } else {
                debugPrint(
                  '[ClipboardService] ⚠ File too large: ${bytes.length} bytes',
                );
              }
            }
          }
        } on Exception catch (e) {
          debugPrint('[ClipboardService] ✗ File URI read failed: $e');
          // Continue to next format
        }
      }

      // Try to read PNG image (second priority)
      if (reader.canProvide(Formats.png)) {
        debugPrint('[ClipboardService] ↓ Reading PNG image');
        final completer = Completer<ClipboardContent?>();

        reader.getFile(
          Formats.png,
          (file) async {
            try {
              final bytes = await file.readAll();
              completer.complete(ClipboardContent.image(bytes, 'image/png'));
            } on Exception catch (_) {
              completer.complete(null);
            }
          },
          onError: (e) {
            completer.complete(null);
          },
        );

        final result = await completer.future;
        if (result != null) return result;
      }

      // Try JPEG image
      if (reader.canProvide(Formats.jpeg)) {
        debugPrint('[ClipboardService] ↓ Reading JPEG image');
        final completer = Completer<ClipboardContent?>();

        reader.getFile(
          Formats.jpeg,
          (file) async {
            try {
              final bytes = await file.readAll();
              completer.complete(ClipboardContent.image(bytes, 'image/jpeg'));
            } on Exception catch (_) {
              completer.complete(null);
            }
          },
          onError: (e) {
            completer.complete(null);
          },
        );

        final result = await completer.future;
        if (result != null) return result;
      }

      // Try to read plain text first (prioritize clean text over HTML)
      if (reader.canProvide(Formats.plainText)) {
        final text = await reader.readValue(Formats.plainText);
        if (text != null && text.isNotEmpty) {
          debugPrint('[ClipboardService] ↓ Read text: ${text.length} chars');
          return ClipboardContent.text(text);
        }
      }

      // Try to read HTML (fallback if no plain text, or if we want to add a setting later)
      if (reader.canProvide(Formats.htmlText)) {
        debugPrint('[ClipboardService] ↓ Reading HTML');
        final html = await reader.readValue(Formats.htmlText);
        if (html != null && html.isNotEmpty) {
          return ClipboardContent.html(html);
        }
      }

      debugPrint('[ClipboardService] ○ Clipboard is empty');
      return const ClipboardContent.empty();
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Read failed: $e');
      return const ClipboardContent.empty();
    }
  }

  @override
  Future<void> writeText(String text) async {
    try {
      final item = DataWriterItem()..add(Formats.plainText(text));

      await SystemClipboard.instance?.write([item]);
      debugPrint('[ClipboardService] ↑ Wrote text: ${text.length} chars');
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Write text failed: $e');
      throw ClipboardException('Failed to write text: $e');
    }
  }

  @override
  Future<void> writeHtml(String html) async {
    try {
      // Strip HTML tags for plain text fallback
      final plainText = html.replaceAll(RegExp('<[^>]*>'), '');

      final item = DataWriterItem()
        ..add(Formats.htmlText(html))
        ..add(Formats.plainText(plainText));

      await SystemClipboard.instance?.write([item]);
      debugPrint('[ClipboardService] ↑ Wrote HTML: ${html.length} chars');
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Write HTML failed: $e');
      throw ClipboardException('Failed to write HTML: $e');
    }
  }

  @override
  Future<void> writeImage(Uint8List bytes) async {
    try {
      final item = DataWriterItem()
        ..add(Formats.png(bytes)); // PNG format (lossless)

      await SystemClipboard.instance?.write([item]);
      debugPrint('[ClipboardService] ↑ Wrote image: ${bytes.length} bytes');
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Write image failed: $e');
      throw ClipboardException('Failed to write image: $e');
    }
  }

  @override
  Future<void> writeFilePath(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw ClipboardException('File does not exist: $filePath');
      }

      final item = DataWriterItem()..add(Formats.fileUri(Uri.file(filePath)));

      await SystemClipboard.instance?.write([item]);
      debugPrint('[ClipboardService] ↑ Wrote file URI: $filePath');
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Write file path failed: $e');
      throw ClipboardException('Failed to write file path: $e');
    }
  }

  @override
  Future<File> writeTempFile(Uint8List bytes, String filename) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$filename');
      await file.writeAsBytes(bytes);
      debugPrint('[ClipboardService] ✓ Wrote temp file: ${file.path}');
      return file;
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Write temp file failed: $e');
      throw ClipboardException('Failed to write temp file: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      // Write empty text to clear the clipboard
      final item = DataWriterItem()..add(Formats.plainText(''));

      final clipboard = SystemClipboard.instance;
      if (clipboard != null) {
        await clipboard.write([item]);
      }
      debugPrint('[ClipboardService] ✓ Clipboard cleared');
    } on Exception catch (e) {
      debugPrint('[ClipboardService] ✗ Clear failed: $e');
      // Don't throw - clearing is best effort
    }
  }
}

/// Exception thrown by ClipboardService operations
class ClipboardException implements Exception {
  ClipboardException(this.message);

  final String message;

  @override
  String toString() => 'ClipboardException: $message';
}
