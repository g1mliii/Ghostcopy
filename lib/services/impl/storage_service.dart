import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage_service.dart';

/// Implementation of Supabase Storage operations
class StorageService implements IStorageService {
  /// Factory constructor with optional client injection for testing
  factory StorageService({SupabaseClient? client}) {
    if (client != null) {
      return StorageService._internal(client: client);
    }
    return instance;
  }

  /// Private constructor for singleton pattern
  StorageService._internal({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  /// Singleton instance
  static final StorageService instance = StorageService._internal();

  final SupabaseClient _client;
  static const String bucketName = 'clipboard-files';

  @override
  Future<void> initialize() async {
    try {
      await _client.storage.getBucket(bucketName);
      debugPrint('[StorageService] ✓ Initialized with bucket: $bucketName');
    } catch (e) {
      debugPrint('[StorageService] ✗ Bucket verification failed: $e');
      rethrow;
    }
  }

  @override
  Future<UploadResult> uploadFile({
    required String userId,
    required String clipboardId,
    required Uint8List bytes,
    required String filename,
    required String mimeType,
  }) async {
    try {
      // Path format: user_id/clip_id/filename
      final storagePath = '$userId/$clipboardId/$filename';

      debugPrint(
        '[StorageService] ↑ Uploading: $storagePath (${bytes.length} bytes)',
      );

      // Upload with upsert to allow overwrites
      await _client.storage.from(bucketName).uploadBinary(
            storagePath,
            bytes,
            fileOptions: FileOptions(
              contentType: mimeType,
              upsert: true,
            ),
          );

      // Get public URL (signed for private bucket)
      final publicUrl =
          _client.storage.from(bucketName).getPublicUrl(storagePath);

      debugPrint('[StorageService] ✓ Uploaded successfully');

      return UploadResult(
        storagePath: storagePath,
        publicUrl: publicUrl,
        fileSizeBytes: bytes.length,
      );
    } catch (e) {
      debugPrint('[StorageService] ✗ Upload failed: $e');
      throw StorageException('Failed to upload file: $e');
    }
  }

  @override
  Future<Uint8List> downloadFile(String storagePath) async {
    try {
      debugPrint('[StorageService] ↓ Downloading: $storagePath');

      final bytes = await _client.storage.from(bucketName).download(storagePath);

      debugPrint('[StorageService] ✓ Downloaded: ${bytes.length} bytes');

      return bytes;
    } catch (e) {
      debugPrint('[StorageService] ✗ Download failed: $e');
      throw StorageException('Failed to download file: $e');
    }
  }

  @override
  Future<void> deleteFile(String storagePath) async {
    try {
      debugPrint('[StorageService] ✗ Deleting: $storagePath');

      await _client.storage.from(bucketName).remove([storagePath]);

      debugPrint('[StorageService] ✓ Deleted successfully');
    } catch (e) {
      debugPrint('[StorageService] ✗ Delete failed: $e');
      throw StorageException('Failed to delete file: $e');
    }
  }

  @override
  void dispose() {
    // No resources to dispose
  }
}

/// Exception thrown by StorageService operations
class StorageException implements Exception {
  StorageException(this.message);

  final String message;

  @override
  String toString() => 'StorageException: $message';
}
