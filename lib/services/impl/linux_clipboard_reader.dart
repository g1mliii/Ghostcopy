import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../models/clipboard_limits.dart';
import '../clipboard_service.dart';

/// Bounded, shell-free access to Wayland's clipboard through wl-clipboard.
///
/// GTK/XWayland cannot reliably read another Wayland client's selection while
/// unfocused. wl-paste uses the compositor's data-control protocol instead.
/// Writes still use super_clipboard's multi-format XWayland offer, which KWin
/// bridges to Wayland (including HTML plus its plain-text alternative).
class LinuxClipboardReader {
  LinuxClipboardReader({Future<Uint8List> Function(List<String>)? paste})
    : _paste = paste ?? _runPaste;

  final Future<Uint8List> Function(List<String>) _paste;

  /// Whether the login session can provide the native Wayland clipboard.
  static bool get isWayland =>
      Platform.isLinux &&
      (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ?? false);

  /// Read using the same file/image/text/HTML priority as ClipboardService.
  Future<ClipboardContent> read() async {
    try {
      final types = await _listTypes();
      // Password managers mark these offers as unsuitable for history/sync.
      if (types.contains('x-kde-passwordManagerHint') ||
          types.contains('application/x-keepassxc-secret')) {
        return const ClipboardContent.empty();
      }
      for (final filePath in await _localFiles(types)) {
        final file = File(filePath);
        if (!file.existsSync() ||
            file.statSync().size > ClipboardLimits.maxFileBytes) {
          continue;
        }
        try {
          final bytes = await readBounded(file.openRead());
          return ClipboardContent.file(bytes, path.posix.basename(file.path));
        } on FormatException {
          // Grew past the limit while being read: skip it like an oversized
          // file, and let the image or text offers still be used.
          continue;
        }
      }
      for (final mime in ['image/png', 'image/jpeg']) {
        if (types.contains(mime)) {
          return ClipboardContent.image(await _readType(mime), mime);
        }
      }
      for (final mime in [
        'text/plain;charset=utf-8',
        'text/plain',
        'UTF8_STRING',
      ]) {
        if (!types.contains(mime)) continue;
        // An empty plain-text alternative falls through to the next offer,
        // as ClipboardService does, rather than discarding valid HTML.
        final text = utf8.decode(await _readType(mime));
        if (text.isNotEmpty) return ClipboardContent.text(text);
      }
      if (types.contains('text/html')) {
        final html = utf8.decode(await _readType('text/html'));
        if (html.isNotEmpty) return ClipboardContent.html(html);
      }
      return const ClipboardContent.empty();
    } on Exception catch (error) {
      // Do not silently fall back to a potentially stale XWayland selection.
      debugPrint('[LinuxClipboard] Read unavailable: $error');
      return const ClipboardContent.unavailable();
    }
  }

  Future<Uint8List> _readType(String mime) =>
      _paste(['--no-newline', '--type', mime]);

  /// Query the active file without loading its contents, for temp retention.
  /// Failures deliberately propagate so cleanup preserves an unknown selection.
  Future<Uri?> readFileUri() async {
    final filePath = (await _localFiles(await _listTypes())).firstOrNull;
    return filePath == null ? null : Uri.file(filePath, windows: false);
  }

  Future<Set<String>> _listTypes() async => const LineSplitter()
      .convert(utf8.decode(await _paste(['--list-types'])))
      .toSet();

  /// Local paths in the offered uri-list. Never treats remote URLs as files or
  /// opens network mounts on behalf of an arbitrary clipboard producer, and
  /// skips URIs with no path form (a query, a fragment, an encoded slash).
  Future<List<String>> _localFiles(Set<String> types) async {
    if (!types.contains('text/uri-list')) return const [];
    final value = utf8.decode(await _readType('text/uri-list'));
    final paths = <String>[];
    for (final line in const LineSplitter().convert(value)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = Uri.tryParse(line);
      if (uri == null || uri.scheme != 'file' || uri.host.isNotEmpty) continue;
      // The cases where toFilePath throws rather than returning a path.
      if (uri.hasQuery ||
          uri.hasFragment ||
          uri.pathSegments.any((segment) => segment.contains('/'))) {
        continue;
      }
      paths.add(uri.toFilePath(windows: false));
    }
    return paths;
  }

  /// Enforce the size bound during streaming, including files that grow.
  @visibleForTesting
  static Future<Uint8List> readBounded(
    Stream<List<int>> stream, {
    int limit = ClipboardLimits.maxFileBytes,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Clipboard exceeds the size limit');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  static Future<Uint8List> _runPaste(List<String> arguments) async {
    final process = await Process.start('wl-paste', arguments);
    try {
      final results = await Future.wait<Object?>([
        readBounded(
          process.stdout,
          limit: arguments.contains('--list-types')
              ? 64 * 1024
              : ClipboardLimits.maxFileBytes,
        ),
        process.stderr.drain<void>(),
        process.exitCode,
      ], eagerError: true).timeout(const Duration(seconds: 5));
      if (results[2] != 0) {
        throw ProcessException('wl-paste', arguments, 'Clipboard unavailable');
      }
      return results[0]! as Uint8List;
    } finally {
      process.kill();
    }
  }
}
