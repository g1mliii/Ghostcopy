import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../packaged_app_data.dart';
import '../temp_file_service.dart';
import 'linux_clipboard_reader.dart';

/// Implementation of temporary file management
class TempFileService implements ITempFileService {
  /// Optional providers allow filesystem and clipboard lifecycle checks in tests.
  TempFileService({
    Future<Directory> Function()? temporaryDirectory,
    Future<Uri?> Function()? clipboardFile,
    Directory? Function()? earlierTemporaryDirectory,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _clipboardFile = clipboardFile ?? _readClipboardFile,
       _earlierTemporaryDirectory =
           earlierTemporaryDirectory ?? _ordinaryTempIfPackaged;

  final Future<Directory> Function() _temporaryDirectory;
  final Future<Uri?> Function() _clipboardFile;

  /// Where an earlier version wrote, if no longer [_temporaryDirectory]: a
  /// Store install now writes under its package, but files from before that
  /// - decrypted downloads - would otherwise outlive an uninstall. Cleaned
  /// with the same rules, the active clipboard file kept.
  final Directory? Function() _earlierTemporaryDirectory;

  static Directory? _ordinaryTempIfPackaged() =>
      PackagedAppData.inUse == null ? null : Directory.systemTemp;
  int _nextFileId = 0;

  /// Singleton instance
  static final TempFileService instance = TempFileService();

  static final _unsafePathChars = RegExp(r'[/\\:]');

  /// What every file this service writes is named with.
  static const String filePrefix = 'ghostcopy_';
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
        path.join(tempDir.path, '$filePrefix${uniqueId}_$safeFilename'),
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
      final cutoffTimestamp = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      final earlier = _earlierTemporaryDirectory();
      final expired = <String>[];
      for (final dir in [
        tempDir.path,
        if (earlier != null && !path.equals(earlier.path, tempDir.path))
          earlier.path,
      ]) {
        expired.addAll(
          await compute(
            _expiredTempFilesInIsolate,
            _TempCleanupParams(dir, filePrefix, cutoffTimestamp),
          ),
        );
      }
      // Asked only when there is something to delete: on Wayland the answer
      // costs wl-paste processes, and this runs every 15 minutes in the tray.
      // If clipboard access fails, retain the files and try again next time.
      // Deleting an unknown active URI would break a pending paste operation.
      final activeUri = expired.isEmpty ? null : await _clipboardFile();
      final activePath = activeUri?.scheme == 'file'
          ? activeUri!.toFilePath()
          : null;
      var deletedCount = 0;
      for (final filePath in expired) {
        if (activePath != null && path.equals(filePath, activePath)) continue;
        try {
          await File(filePath).delete();
          deletedCount++;
        } on FileSystemException {
          // Best effort cleanup only.
        }
      }

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
    if (LinuxClipboardReader.isWayland) {
      return LinuxClipboardReader().readFileUri();
    }
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
      if (!path.basename(filePath).startsWith(filePrefix)) {
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
  );

  final String tempDirPath;
  final String filePrefix;
  final int cutoffEpochMs;
}

/// Our temp files last modified before the cutoff.
List<String> _expiredTempFilesInIsolate(_TempCleanupParams params) {
  final tempDir = Directory(params.tempDirPath);
  if (!tempDir.existsSync()) return const [];

  final cutoff = DateTime.fromMillisecondsSinceEpoch(params.cutoffEpochMs);
  final expired = <String>[];

  for (final entity in tempDir.listSync()) {
    if (entity is! File) continue;
    if (!path.basename(entity.path).startsWith(params.filePrefix)) continue;
    try {
      if (entity.statSync().modified.isBefore(cutoff)) expired.add(entity.path);
    } on Exception {
      // Best effort cleanup only.
    }
  }

  return expired;
}
