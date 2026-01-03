import 'dart:typed_data';

export 'impl/storage_service.dart';

/// Result of file upload operation
class UploadResult {
  const UploadResult({
    required this.storagePath,
    required this.publicUrl,
    required this.fileSizeBytes,
  });

  final String storagePath; // Path in storage bucket
  final String publicUrl; // Public URL to access file
  final int fileSizeBytes; // Size of uploaded file

  @override
  String toString() =>
      'UploadResult(storagePath: $storagePath, fileSizeBytes: $fileSizeBytes)';
}

/// Abstract interface for Supabase Storage operations
abstract class IStorageService {
  /// Upload file bytes to Supabase Storage
  ///
  /// Creates path: user_id/clipboard_id/filename
  /// Returns UploadResult with storage path and public URL
  Future<UploadResult> uploadFile({
    required String userId,
    required String clipboardId,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  });

  /// Download file bytes from Supabase Storage
  ///
  /// Returns file bytes or null if not found
  Future<Uint8List> downloadFile(String storagePath);

  /// Delete file from Supabase Storage
  ///
  /// Removes file at the given storage path
  Future<void> deleteFile(String storagePath);

  /// Initialize storage service
  ///
  /// Verifies bucket exists and is accessible
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
