import 'dart:io';
import 'dart:typed_data';

export 'impl/temp_file_service.dart';

/// Abstract interface for temporary file management
abstract class ITempFileService {
  /// Save bytes to a temporary file with the given filename
  ///
  /// Files are prefixed with 'ghostcopy_' for easy identification
  /// Returns the created File object
  Future<File> saveTempFile(Uint8List bytes, String filename);

  /// Clean up old temporary files (older than 1 hour)
  ///
  /// Should be called on app start to remove leftover files
  Future<void> cleanupTempFiles();

  /// Delete a specific temporary file
  ///
  /// Safe to call even if file doesn't exist
  Future<void> deleteTempFile(String filePath);
}
