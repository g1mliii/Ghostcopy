import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../temp_file_service.dart';

/// Implementation of temporary file management
class TempFileService implements ITempFileService {
  /// Optional providers allow filesystem and clipboard lifecycle checks in tests.
  TempFileService({
    Future<Directory> Function()? temporaryDirectory,
    Future<Uri?> Function()? clipboardFile,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _clipboardFile = clipboardFile ?? _readClipboardFile;

  final Future<Directory> Function() _temporaryDirectory;
  final Future<Uri?> Function() _clipboardFile;
  int _nextFileId = 0;

  /// Singleton instance
  static final TempFileService instance = TempFileService();

  static final _unsafePathChars = RegExp(r'[/\\:]');

  static const String _filePrefix = 'ghostcopy_';
  Timer? _periodicCleanupTimer;

  @override
  Future<File> saveTempFile(Uint8List bytes, String filename) async {
    try {
      final tempDir = await _temporaryDirectory();

      // Create safe filename by removing path separators
      final safeFilename = filename.replaceAll(_unsafePathChars, '_');

      final uniqueId =
          '${DateTime.now().microsecondsSinceEpoch}_${_nextFileId++}';
      final file = File(
        path.join(tempDir.path, '$_filePrefix${uniqueId}_$safeFilename'),
      );

      await file.writeAsBytes(bytes);

      debugPrint(
        '[TempFileService] ✓ Saved temp file: ${file.path} (${bytes.length} bytes)',
      );

      return file;
    } catch (e) {
      debugPrint('[TempFileService] ✗ Failed to save temp file: $e');
      rethrow;
    }
  }

  @override
  Future<void> cleanupTempFiles() async {
    try {
      final tempDir = await _temporaryDirectory();
      // If clipboard access fails, retain the files and try again next time.
      // Deleting an unknown active URI would break a pending paste operation.
      final activeUri = await _clipboardFile();
      final activePath = activeUri?.scheme == 'file'
          ? activeUri!.toFilePath()
          : null;
      final cutoffTimestamp = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      final deletedCount = await compute(
        _cleanupTempFilesInIsolate,
        _TempCleanupParams(
          tempDir.path,
          _filePrefix,
          cutoffTimestamp,
          activePath,
        ),
      );

      if (deletedCount > 0) {
        debugPrint(
          '[TempFileService] ✓ Cleaned up $deletedCount old temp files',
        );
      } else {
        debugPrint('[TempFileService] ○ No old temp files to clean up');
      }
    } on Exception catch (e) {
      debugPrint('[TempFileService] ✗ Cleanup failed: $e');
      // Don't throw - cleanup is best effort
    }
  }

  static Future<Uri?> _readClipboardFile() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) throw Exception('Clipboard unavailable');
    final reader = await clipboard.read();
    if (!reader.canProvide(Formats.fileUri)) return null;
    return reader.readValue(Formats.fileUri);
  }

  @override
  Future<void> deleteTempFile(String filePath) async {
    try {
      final file = File(filePath);

      // Only delete if it's one of our temp files (safety check)
      if (!path.basename(filePath).startsWith(_filePrefix)) {
        debugPrint(
          '[TempFileService] ⚠ Refusing to delete non-temp file: $filePath',
        );
        return;
      }

      if (file.existsSync()) {
        await file.delete();
        debugPrint('[TempFileService] ✓ Deleted temp file: $filePath');
      }
    } on Exception catch (e) {
      debugPrint('[TempFileService] ✗ Failed to delete temp file: $e');
      // Don't throw - deletion is best effort
    }
  }

  /// Start periodic cleanup timer (runs every 15 minutes)
  ///
  /// Should be called once on app startup after initial cleanup
  void startPeriodicCleanup() {
    // Cancel existing timer if any
    _periodicCleanupTimer?.cancel();

    // Run cleanup every 15 minutes
    _periodicCleanupTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      cleanupTempFiles();
    });

    debugPrint('[TempFileService] 🔄 Periodic cleanup started (every 15 min)');
  }

  /// Stop periodic cleanup timer
  ///
  /// Should be called on app shutdown for cleanup
  void stopPeriodicCleanup() {
    _periodicCleanupTimer?.cancel();
    _periodicCleanupTimer = null;
    debugPrint('[TempFileService] ⏹ Periodic cleanup stopped');
  }
}

class _TempCleanupParams {
  const _TempCleanupParams(
    this.tempDirPath,
    this.filePrefix,
    this.cutoffEpochMs,
    this.activePath,
  );

  final String tempDirPath;
  final String filePrefix;
  final int cutoffEpochMs;
  final String? activePath;
}

int _cleanupTempFilesInIsolate(_TempCleanupParams params) {
  final tempDir = Directory(params.tempDirPath);
  if (!tempDir.existsSync()) return 0;

  final cutoff = DateTime.fromMillisecondsSinceEpoch(params.cutoffEpochMs);
  var deletedCount = 0;

  for (final entity in tempDir.listSync()) {
    if (entity is! File) continue;
    if (!path.basename(entity.path).startsWith(params.filePrefix)) continue;
    if (params.activePath != null &&
        path.equals(entity.path, params.activePath!)) {
      continue;
    }

    try {
      final stat = entity.statSync();
      if (stat.modified.isBefore(cutoff)) {
        entity.deleteSync();
        deletedCount++;
      }
    } on Exception {
      // Best effort cleanup only.
    }
  }

  return deletedCount;
}
