import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage_service.dart';

/// Implementation of Storage operations using Cloudflare R2
///
/// Upload: get presigned URL from edge function → Flutter PUTs directly to R2
///         (client → R2 direct, no Supabase bandwidth cost)
/// Download: GET directly from R2 public URL (bucket is public, no auth needed)
/// Delete: call edge function which deletes from R2 server-side
class StorageService implements IStorageService {
  factory StorageService({SupabaseClient? client}) {
    if (client != null) {
      return StorageService._internal(client: client);
    }
    return instance;
  }

  StorageService._internal({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static final StorageService instance = StorageService._internal();

  final SupabaseClient _client;
  static const String _edgeFunctionName = 'storage-presign';

  /// R2 public URL — matches R2_PUBLIC_URL in edge function secrets
  static const String _r2PublicUrlBase =
      'https://pub-17ef3eab5b964206b0ec1359b6fd8c53.r2.dev';

  @override
  Future<void> initialize() async {
    debugPrint('[StorageService] ✓ Initialized (R2 via presigned URLs)');
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
      final storagePath = '$userId/$clipboardId/$filename';

      debugPrint(
        '[StorageService] ↑ Uploading to R2: $storagePath (${bytes.length} bytes)',
      );

      // 1. Get presigned upload URL from edge function
      final presignData = await _callEdgeFunctionJson({
        'action': 'upload',
        'path': storagePath,
        'contentType': mimeType,
        'size': bytes.length,
      });

      final presignedUrl = presignData['presignedUrl'] as String;
      final publicUrl = presignData['publicUrl'] as String? ??
          '$_r2PublicUrlBase/$storagePath';

      debugPrint('[StorageService] → PUT directly to R2 presigned URL');

      // 2. PUT bytes directly to R2 — bypasses Supabase bandwidth entirely
      final uploadResponse = await http
          .put(Uri.parse(presignedUrl), body: bytes)
          .timeout(const Duration(minutes: 10));

      if (uploadResponse.statusCode != 200) {
        throw StorageException(
          'R2 upload failed with status ${uploadResponse.statusCode}: '
          '${uploadResponse.body}',
        );
      }

      debugPrint('[StorageService] ✓ Uploaded to R2 successfully');

      return UploadResult(
        storagePath: storagePath,
        publicUrl: publicUrl,
        fileSizeBytes: bytes.length,
      );
    } catch (e) {
      debugPrint('[StorageService] ✗ Upload failed: $e');
      if (e is StorageException) rethrow;
      throw StorageException('Failed to upload file: $e');
    }
  }

  @override
  Future<Uint8List> downloadFile(String storagePath) async {
    try {
      debugPrint('[StorageService] ↓ Downloading from R2: $storagePath');

      // R2 bucket is public — direct download, no Supabase bandwidth cost
      final url = '$_r2PublicUrlBase/$storagePath';
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(minutes: 2));

      if (response.statusCode != 200) {
        throw StorageException(
          'R2 download failed with status ${response.statusCode}',
        );
      }

      final bytes = response.bodyBytes;
      debugPrint('[StorageService] ✓ Downloaded: ${bytes.length} bytes');

      return bytes;
    } catch (e) {
      debugPrint('[StorageService] ✗ Download failed: $e');
      if (e is StorageException) rethrow;
      throw StorageException('Failed to download file: $e');
    }
  }

  @override
  Future<void> deleteFile(String storagePath) async {
    try {
      debugPrint('[StorageService] ✗ Deleting from R2: $storagePath');

      await _callEdgeFunctionJson({
        'action': 'delete',
        'path': storagePath,
      });

      debugPrint('[StorageService] ✓ Deleted from R2 successfully');
    } catch (e) {
      debugPrint('[StorageService] ✗ Delete failed: $e');
      if (e is StorageException) rethrow;
      throw StorageException('Failed to delete file: $e');
    }
  }

  @override
  void dispose() {}

  Future<Map<String, dynamic>> _callEdgeFunctionJson(
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _client.functions.invoke(
        _edgeFunctionName,
        body: body,
      );

      if (response.status != 200) {
        final errorBody = response.data is String
            ? response.data as String
            : json.encode(response.data);
        throw StorageException(
          'Edge function returned status ${response.status}: $errorBody',
        );
      }

      final data = response.data as Map<String, dynamic>;
      if (data.containsKey('error')) {
        throw StorageException('Edge function error: ${data['error']}');
      }

      return data;
    } on StorageException {
      rethrow;
    } catch (e) {
      throw StorageException('Edge function call failed: $e');
    }
  }
}

/// Exception thrown by StorageService operations
class StorageException implements Exception {
  StorageException(this.message);

  final String message;

  @override
  String toString() => 'StorageException: $message';
}
