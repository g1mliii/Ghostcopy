import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../temp_file_service.dart';

/// Implementation of temporary file management
class TempFileService implements ITempFileService {
  TempFileService._();

  /// Singleton instance
  static final TempFileService instance = TempFileService._();

  static const String _filePrefix = 'ghostcopy_';

  @override
  Future<File> saveTempFile(Uint8List bytes, String filename) async {
    try {
      final tempDir = await getTemporaryDirectory();

      // Create safe filename by removing path separators
      final safeFilename = filename.replaceAll(RegExp(r'[/\\:]'), '_');

      final file = File(path.join(tempDir.path, '$_filePrefix$safeFilename'));

      await file.writeAsBytes(bytes);

      debugPrint('[TempFileService] ✓ Saved temp file: ${file.path} (${bytes.length} bytes)');

      return file;
    } catch (e) {
      debugPrint('[TempFileService] ✗ Failed to save temp file: $e');
      rethrow;
    }
  }

  @override
  Future<void> cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();

      final files = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => path.basename(f.path).startsWith(_filePrefix));

      final now = DateTime.now();
      var deletedCount = 0;

      for (final file in files) {
        try {
          final stat = file.statSync();
          final age = now.difference(stat.modified);

          // Delete files older than 1 hour
          if (age.inHours >= 1) {
            await file.delete();
            deletedCount++;
          }
        } on Exception catch (e) {
          // Skip files that can't be deleted (might be in use)
          debugPrint('[TempFileService] ⚠ Could not delete ${file.path}: $e');
        }
      }

      if (deletedCount > 0) {
        debugPrint('[TempFileService] ✓ Cleaned up $deletedCount old temp files');
      } else {
        debugPrint('[TempFileService] ○ No old temp files to clean up');
      }
    } on Exception catch (e) {
      debugPrint('[TempFileService] ✗ Cleanup failed: $e');
      // Don't throw - cleanup is best effort
    }
  }

  @override
  Future<void> deleteTempFile(String filePath) async {
    try {
      final file = File(filePath);

      // Only delete if it's one of our temp files (safety check)
      if (!path.basename(filePath).startsWith(_filePrefix)) {
        debugPrint('[TempFileService] ⚠ Refusing to delete non-temp file: $filePath');
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
}
