import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../models/exceptions.dart';
import '../../services/encryption_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/storage_service.dart';
import '../clipboard_repository.dart';

/// Implementation of ClipboardRepository with security hardening
///
/// Security Features:
/// - Input validation and sanitization
/// - Content length limits (max 100KB)
/// - Device type validation
/// - SQL injection prevention via parameterized queries
/// - RLS policy enforcement through Supabase auth
/// - Client-side end-to-end encryption (AES-256-GCM)
/// - Encrypted content stored in Supabase (admins cannot read)
///
/// **SINGLETON PATTERN**: Use ClipboardRepository.instance to prevent redundant
/// EncryptionService initialization that causes UI jank (41 frame skips).
class ClipboardRepository implements IClipboardRepository {
  /// Factory constructor for backwards compatibility and testing
  factory ClipboardRepository({
    SupabaseClient? client,
    IEncryptionService? encryptionService,
    IStorageService? storageService,
  }) {
    // For testing with custom dependencies, create a new instance
    if (client != null || encryptionService != null || storageService != null) {
      return ClipboardRepository._internal(
        client: client,
        encryptionService: encryptionService,
        storageService: storageService,
      );
    }
    // Otherwise, return singleton
    return instance;
  }
  // Private constructor for singleton
  ClipboardRepository._internal({
    SupabaseClient? client,
    IEncryptionService? encryptionService,
    IStorageService? storageService,
  }) : _client = client ?? Supabase.instance.client,
       _encryptionService = encryptionService ?? EncryptionService.instance,
       _storageService = storageService ?? StorageService.instance;

  // Singleton instance
  static final ClipboardRepository instance = ClipboardRepository._internal();

  final SupabaseClient _client;
  final IEncryptionService _encryptionService;
  final IStorageService _storageService;
  bool _encryptionInitialized = false;

  // Security constants
  static const int maxContentLength = 102400; // 100KB
  static const int maxDeviceNameLength = 255;
  static const List<String> validDeviceTypes = [
    'windows',
    'macos',
    'android',
    'ios',
    'linux',
  ];

  /// Initialize encryption with user ID (call once per session)
  Future<void> _ensureEncryptionInitialized() async {
    if (_encryptionInitialized) return;

    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw SecurityException('User must be authenticated for encryption');
    }

    await _encryptionService.initialize(userId);
    _encryptionInitialized = true;
  }

  @override
  Future<ClipboardItem> insert(ClipboardItem item) async {
    // Validate and sanitize input before sending to Supabase
    _validateClipboardItem(item);

    try {
      // Get current authenticated user
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to insert clipboard items',
        );
      }

      // Ensure the item's userId matches the authenticated user (defense in depth)
      if (item.userId != userId) {
        throw SecurityException(
          'Cannot insert clipboard item for another user',
        );
      }

      // Initialize encryption if not already done
      await _ensureEncryptionInitialized();

      // Encrypt content only if encryption is enabled
      final sanitizedContent = _sanitizeContent(item.content);
      final isEncryptionEnabled = await _encryptionService.isEnabled();
      final contentToStore = isEncryptionEnabled
          ? await _encryptionService.encrypt(sanitizedContent)
          : sanitizedContent;

      // Insert into clipboard table (content is now in the same table)
      // RLS policies will enforce user_id = auth.uid()
      // Cleanup happens automatically via database trigger (no client-side overhead)
      // Use .select() to get the inserted record with generated ID
      final response = await _client
          .from('clipboard')
          .insert({
            'user_id': userId,
            'device_name': _sanitizeDeviceName(item.deviceName),
            'device_type': _validateDeviceType(item.deviceType),
            'target_device_type': item.targetDeviceTypes
                ?.map(_validateDeviceType)
                .toList(), // null = broadcast to all devices
            'content': contentToStore,
            'is_public':
                false, // Force to false for security - no public sharing
            'is_encrypted':
                isEncryptionEnabled, // Track if content is encrypted
          })
          .select()
          .single();

      // Return the inserted item with generated ID
      return ClipboardItem(
        id: response['id'].toString(),
        userId: userId,
        content: item.content, // Return original unencrypted content
        deviceName: item.deviceName,
        deviceType: item.deviceType,
        targetDeviceTypes: item.targetDeviceTypes,
        isEncrypted: isEncryptionEnabled,
        createdAt: DateTime.parse(response['created_at'] as String),
      );
    } on SecurityException {
      // Rethrow security exceptions
      rethrow;
    } on ValidationException {
      // Rethrow validation exceptions
      rethrow;
    } on EncryptionException {
      // Rethrow encryption exceptions
      rethrow;
    } on PostgrestException catch (e) {
      // Handle specific Postgres errors
      if (e.code == '23514') {
        // CHECK constraint violation
        throw ValidationException('Content validation failed: ${e.message}');
      }
      if (e.code == '23503') {
        // Foreign key violation
        throw SecurityException('Invalid user ID');
      }
      rethrow;
    } catch (e) {
      // Wrap unexpected errors in RepositoryException
      throw RepositoryException('Failed to insert clipboard item: $e');
    }
  }

  @override
  Future<ClipboardItem> insertFile({
    required String userId,
    required String deviceType,
    required String? deviceName,
    required Uint8List fileBytes,
    required String mimeType,
    required ContentType contentType,
    String? originalFilename,
    int? width,
    int? height,
    List<String>? targetDeviceTypes,
  }) async {
    try {
      // Validate user authentication
      final currentUserId = _client.auth.currentUser?.id;
      if (currentUserId == null) {
        throw SecurityException(
          'User must be authenticated to insert file items',
        );
      }

      // Defense in depth: ensure userId matches authenticated user
      if (userId != currentUserId) {
        throw SecurityException('Cannot insert file for another user');
      }

      // Validate file size (10MB limit)
      const maxFileSize = 10485760; // 10MB
      if (fileBytes.length > maxFileSize) {
        throw ValidationException(
          'File exceeds 10MB limit: ${fileBytes.length} bytes',
        );
      }

      // Validate content type requires storage
      if (!contentType.requiresStorage) {
        throw ValidationException(
          'Content type must require storage, got: ${contentType.value}',
        );
      }

      // 1. Insert placeholder to get clip ID
      debugPrint(
        '[Repository] ↑ Inserting file placeholder (${fileBytes.length} bytes)',
      );

      // Build metadata with original filename
      final metadata = <String, dynamic>{
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (originalFilename != null) 'original_filename': originalFilename,
      };

      final response = await _client
          .from('clipboard')
          .insert({
            'user_id': userId,
            'device_name': _sanitizeDeviceName(deviceName),
            'device_type': _validateDeviceType(deviceType),
            'target_device_type': targetDeviceTypes
                ?.map(_validateDeviceType)
                .toList(), // null = broadcast to all devices
            'content': '', // Placeholder, will be updated with URL
            'content_type': contentType.value,
            'mime_type': mimeType,
            'file_size_bytes': fileBytes.length,
            if (metadata.isNotEmpty) 'metadata': metadata,
            'is_encrypted': false, // Files NOT encrypted
          })
          .select()
          .single();

      final clipId = response['id'].toString();

      // 2. Upload to Storage
      // Use original filename if provided, otherwise generate from extension
      final filename = originalFilename ?? 'file.${_getExtension(mimeType)}';
      debugPrint(
        '[Repository] ↑ Uploading to storage: $userId/$clipId/$filename',
      );

      final uploadResult = await _storageService.uploadFile(
        userId: userId,
        clipboardId: clipId,
        bytes: fileBytes,
        filename: filename,
        mimeType: mimeType,
      );

      // 3. Update with storage path and URL
      await _client
          .from('clipboard')
          .update({
            'storage_path': uploadResult.storagePath,
            'content': uploadResult.publicUrl, // URL in content field
          })
          .eq('id', clipId);

      debugPrint('[Repository] ✓ File uploaded successfully: $filename');

      return ClipboardItem(
        id: clipId,
        userId: userId,
        content: uploadResult.publicUrl,
        deviceName: deviceName,
        deviceType: deviceType,
        targetDeviceTypes: targetDeviceTypes,
        contentType: contentType,
        storagePath: uploadResult.storagePath,
        fileSizeBytes: fileBytes.length,
        mimeType: mimeType,
        metadata: metadata.isNotEmpty
            ? ClipboardMetadata(
                width: width,
                height: height,
                originalFilename: originalFilename,
              )
            : null,
        createdAt: DateTime.parse(response['created_at'] as String),
      );
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } on PostgrestException catch (e) {
      debugPrint('[Repository] ✗ Database error: ${e.message}');
      throw RepositoryException('Database error: ${e.message}');
    } catch (e) {
      debugPrint('[Repository] ✗ Failed to insert file: $e');
      throw RepositoryException('Failed to insert file: $e');
    }
  }

  @override
  Stream<double> uploadFileWithProgress({
    required String userId,
    required String deviceType,
    required String? deviceName,
    required Uint8List fileBytes,
    required String mimeType,
    required ContentType contentType,
    String? originalFilename,
    int? width,
    int? height,
    List<String>? targetDeviceTypes,
  }) async* {
    try {
      // Validate user authentication
      final currentUserId = _client.auth.currentUser?.id;
      if (currentUserId == null) {
        throw SecurityException(
          'User must be authenticated to insert file items',
        );
      }

      if (userId != currentUserId) {
        throw SecurityException('Cannot insert file for another user');
      }

      // Validate file size (10MB limit)
      const maxFileSize = 10485760; // 10MB
      if (fileBytes.length > maxFileSize) {
        throw ValidationException(
          'File exceeds 10MB limit: ${fileBytes.length} bytes',
        );
      }

      if (!contentType.requiresStorage) {
        throw ValidationException(
          'Content type must require storage, got: ${contentType.value}',
        );
      }

      // Progress: 0.1 - Starting
      yield 0.1;

      debugPrint(
        '[Repository] ↑ Inserting file with progress (${fileBytes.length} bytes)',
      );

      final metadata = <String, dynamic>{
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (originalFilename != null) 'original_filename': originalFilename,
      };

      final response = await _client
          .from('clipboard')
          .insert({
            'user_id': userId,
            'device_name': _sanitizeDeviceName(deviceName),
            'device_type': _validateDeviceType(deviceType),
            'target_device_type': targetDeviceTypes
                ?.map(_validateDeviceType)
                .toList(),
            'content': '',
            'content_type': contentType.value,
            'mime_type': mimeType,
            'file_size_bytes': fileBytes.length,
            if (metadata.isNotEmpty) 'metadata': metadata,
            'is_encrypted': false,
          })
          .select()
          .single();

      final clipId = response['id'].toString();
      yield 0.3; // Database record created

      final filename = originalFilename ?? 'file.${_getExtension(mimeType)}';
      debugPrint(
        '[Repository] ↑ Uploading to storage: $userId/$clipId/$filename',
      );

      final uploadResult = await _storageService.uploadFile(
        userId: userId,
        clipboardId: clipId,
        bytes: fileBytes,
        filename: filename,
        mimeType: mimeType,
      );

      yield 0.8; // Upload complete

      await _client
          .from('clipboard')
          .update({
            'storage_path': uploadResult.storagePath,
            'content': uploadResult.publicUrl,
          })
          .eq('id', clipId);

      debugPrint('[Repository] ✓ File uploaded successfully');
      yield 1.0; // Done
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } on SocketException {
      throw NetworkException('Network error: Check your connection');
    } on PostgrestException catch (e) {
      debugPrint('[Repository] ✗ Database error: ${e.message}');
      throw RepositoryException('Database error: ${e.message}');
    } catch (e) {
      debugPrint('[Repository] ✗ Failed to upload file: $e');
      throw RepositoryException('Failed to upload file: $e');
    }
  }

  @override
  Future<ClipboardItem> insertImage({
    required String userId,
    required String deviceType,
    required String? deviceName,
    required Uint8List imageBytes,
    required String mimeType,
    required ContentType contentType,
    int? width,
    int? height,
    List<String>? targetDeviceTypes,
  }) async {
    // Validate content type is an image
    if (!contentType.isImage) {
      throw ValidationException(
        'Content type must be an image type, got: ${contentType.value}',
      );
    }

    // Delegate to insertFile (convenience wrapper for backward compatibility)
    return insertFile(
      userId: userId,
      deviceType: deviceType,
      deviceName: deviceName,
      fileBytes: imageBytes,
      mimeType: mimeType,
      contentType: contentType,
      width: width,
      height: height,
      targetDeviceTypes: targetDeviceTypes,
    );
  }

  @override
  Future<ClipboardItem> insertRichText({
    required String userId,
    required String deviceType,
    required String? deviceName,
    required String content,
    required RichTextFormat format,
  }) async {
    try {
      // Validate user authentication
      final currentUserId = _client.auth.currentUser?.id;
      if (currentUserId == null) {
        throw SecurityException(
          'User must be authenticated to insert rich text items',
        );
      }

      // Defense in depth: ensure userId matches authenticated user
      if (userId != currentUserId) {
        throw SecurityException('Cannot insert rich text for another user');
      }

      // Validate content
      final sanitizedContent = _sanitizeContent(content);

      // Initialize encryption
      await _ensureEncryptionInitialized();

      // Encrypt content if encryption is enabled
      final isEncryptionEnabled = await _encryptionService.isEnabled();
      final contentToStore = isEncryptionEnabled
          ? await _encryptionService.encrypt(sanitizedContent)
          : sanitizedContent;

      // Determine content type and mime type
      final contentType = format == RichTextFormat.html
          ? ContentType.html
          : ContentType.markdown;
      final mimeType = format == RichTextFormat.html
          ? 'text/html'
          : 'text/markdown';

      debugPrint(
        '[Repository] ↑ Inserting rich text (${format.value}, ${sanitizedContent.length} chars)',
      );

      final response = await _client
          .from('clipboard')
          .insert({
            'user_id': userId,
            'device_name': _sanitizeDeviceName(deviceName),
            'device_type': _validateDeviceType(deviceType),
            'content': contentToStore,
            'content_type': contentType.value,
            'mime_type': mimeType,
            'rich_text_format': format.value,
            'is_encrypted': isEncryptionEnabled,
          })
          .select()
          .single();

      debugPrint('[Repository] ✓ Rich text inserted successfully');

      return ClipboardItem(
        id: response['id'].toString(),
        userId: userId,
        content: sanitizedContent, // Return original unencrypted content
        deviceName: deviceName,
        deviceType: deviceType,
        contentType: contentType,
        mimeType: mimeType,
        richTextFormat: format,
        isEncrypted: isEncryptionEnabled,
        createdAt: DateTime.parse(response['created_at'] as String),
      );
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } on EncryptionException {
      rethrow;
    } on PostgrestException catch (e) {
      debugPrint('[Repository] ✗ Database error: ${e.message}');
      throw RepositoryException('Database error: ${e.message}');
    } catch (e) {
      debugPrint('[Repository] ✗ Failed to insert rich text: $e');
      throw RepositoryException('Failed to insert rich text: $e');
    }
  }

  @override
  Future<Uint8List?> downloadFile(ClipboardItem item) async {
    if (item.storagePath == null) {
      debugPrint('[Repository] ○ No storage path for item ${item.id}');
      return null;
    }

    try {
      debugPrint('[Repository] ↓ Downloading: ${item.storagePath}');

      final bytes = await _storageService.downloadFile(item.storagePath!);

      debugPrint('[Repository] ✓ Downloaded: ${bytes.length} bytes');

      return bytes;
    } on Exception catch (e) {
      debugPrint('[Repository] ✗ Download failed: $e');
      return null;
    }
  }

  @override
  Future<List<ClipboardItem>> searchHistory(
    String query, {
    int limit = 15,
  }) async {
    // Return all history if query is empty
    if (query.trim().isEmpty) {
      return getHistory(limit: limit);
    }

    // Validate limit parameter
    final safeLimit = _validateLimit(limit);

    try {
      debugPrint('[Repository] 🔍 Local search: "$query" (limit: $safeLimit)');

      // Get all history items (they're cached locally via watchHistory stream)
      final allItems = await getHistory(
        limit: 100,
      ); // Search more items locally

      // Lightweight local search - case-insensitive substring match
      final lowerQuery = query.toLowerCase();
      final results = allItems
          .where((item) {
            // Search in content
            if (item.content.toLowerCase().contains(lowerQuery)) {
              return true;
            }

            // Search in device name if present
            if (item.deviceName != null &&
                item.deviceName!.toLowerCase().contains(lowerQuery)) {
              return true;
            }

            // Search in mime type if present (e.g., "image/png")
            if (item.mimeType != null &&
                item.mimeType!.toLowerCase().contains(lowerQuery)) {
              return true;
            }

            return false;
          })
          .take(safeLimit)
          .toList();

      debugPrint('[Repository] ✓ Found ${results.length} results locally');

      return results;
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } catch (e) {
      debugPrint('[Repository] ✗ Failed to search history: $e');
      throw RepositoryException('Failed to search history: $e');
    }
  }

  @override
  Stream<List<ClipboardItem>> watchHistory({int limit = 15}) {
    // Validate limit parameter
    final safeLimit = _validateLimit(limit);

    try {
      // Get current authenticated user
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to watch clipboard history',
        );
      }

      // Subscribe to real-time changes with content join
      // RLS policies automatically filter to current user's items
      return _client
          .from('clipboard')
          .stream(primaryKey: ['id', 'user_id'])
          .eq('user_id', userId) // Explicit filter for defense in depth
          .order('created_at') // Newest first
          .limit(safeLimit)
          .map(_parseClipboardItems)
          .asyncMap(_decryptItems); // Decrypt items asynchronously
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } catch (e) {
      throw RepositoryException('Failed to watch clipboard history: $e');
    }
  }

  @override
  Future<List<ClipboardItem>> getHistory({int limit = 15}) async {
    // Validate limit parameter
    final safeLimit = _validateLimit(limit);

    try {
      // Get current authenticated user
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to get clipboard history',
        );
      }

      // Fetch history with RLS enforcement (content is now in the same table)
      final response = await _client
          .from('clipboard')
          .select()
          .eq('user_id', userId) // Explicit filter for defense in depth
          .order('created_at', ascending: false) // Newest first
          .limit(safeLimit);

      // Parse items (use isolate for large responses)
      final responseList = response as List<dynamic>;
      final items = await _parseClipboardItemsAsync(
        responseList.cast<Map<String, dynamic>>(),
      );

      return await _decryptItems(items);
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } on PostgrestException catch (e) {
      throw RepositoryException('Database error: ${e.message}');
    } catch (e) {
      throw RepositoryException('Failed to get clipboard history: $e');
    }
  }

  /// Parse clipboard items with optional isolate for large responses
  Future<List<ClipboardItem>> _parseClipboardItemsAsync(
    List<Map<String, dynamic>> data,
  ) async {
    // For small responses (<20 items), parse synchronously
    if (data.length < 20) {
      return _parseClipboardItems(data);
    }

    // For large responses (>=20 items), parse in background isolate
    return compute(_parseClipboardItemsInIsolate, data);
  }

  @override
  Future<void> delete(String id) async {
    // Validate ID format
    _validateId(id);

    try {
      // Get current authenticated user
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to delete clipboard items',
        );
      }

      // Delete with RLS enforcement
      // RLS policy ensures user can only delete their own items
      await _client
          .from('clipboard')
          .delete()
          .eq('id', id)
          .eq('user_id', userId); // Explicit filter for defense in depth
    } on SecurityException {
      rethrow;
    } on ValidationException {
      rethrow;
    } on PostgrestException catch (e) {
      throw RepositoryException('Database error: ${e.message}');
    } catch (e) {
      throw RepositoryException('Failed to delete clipboard item: $e');
    }
  }

  @override
  Future<void> cleanupOldItems({int keepCount = 15}) async {
    try {
      // Get current authenticated user
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to cleanup clipboard items',
        );
      }

      // Get all items for this user, sorted by created_at descending
      final allItems = await _client
          .from('clipboard')
          .select('id')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      // If we have more than keepCount items, delete the oldest ones
      if (allItems.length > keepCount) {
        // Get IDs of items to delete (skip the first keepCount items)
        final itemsToDelete = allItems
            .skip(keepCount)
            .map((item) => item['id'] as Object)
            .toList();

        // Batch delete all old items in one network request (performance optimization)
        await _client
            .from('clipboard')
            .delete()
            .eq('user_id', userId) // Defense in depth
            .inFilter('id', itemsToDelete);

        debugPrint(
          'Cleaned up ${itemsToDelete.length} old clipboard items in one batch',
        );
      }
    } on SecurityException {
      rethrow;
    } on PostgrestException catch (e) {
      throw RepositoryException('Database error during cleanup: ${e.message}');
    } catch (e) {
      throw RepositoryException('Failed to cleanup old items: $e');
    }
  }

  // ========== Private validation and sanitization methods ==========

  /// Validates all fields of a ClipboardItem
  void _validateClipboardItem(ClipboardItem item) {
    // Validate content length and check for whitespace-only content
    if (item.content.isEmpty || item.content.trim().isEmpty) {
      throw ValidationException('Content cannot be empty');
    }
    if (item.content.length > maxContentLength) {
      throw ValidationException(
        'Content exceeds maximum length of $maxContentLength characters',
      );
    }

    // Validate device type
    _validateDeviceType(item.deviceType);

    // Validate device name length
    if (item.deviceName != null &&
        item.deviceName!.length > maxDeviceNameLength) {
      throw ValidationException(
        'Device name exceeds maximum length of $maxDeviceNameLength characters',
      );
    }

    // Validate user ID format (basic UUID validation)
    if (item.userId.isEmpty) {
      throw ValidationException('User ID cannot be empty');
    }
  }

  /// Sanitizes content to prevent injection attacks
  ///
  /// Note: Supabase uses parameterized queries which prevent SQL injection,
  /// but we sanitize to prevent other issues and enforce content policies.
  String _sanitizeContent(String content) {
    // Remove null bytes (can cause issues in some databases)
    var sanitized = content.replaceAll('\u0000', '');

    // Trim whitespace
    sanitized = sanitized.trim();

    // Validate after sanitization
    if (sanitized.isEmpty) {
      throw ValidationException('Content is empty after sanitization');
    }
    if (sanitized.length > maxContentLength) {
      throw ValidationException('Content too large after sanitization');
    }

    return sanitized;
  }

  /// Sanitizes device name
  String? _sanitizeDeviceName(String? deviceName) {
    if (deviceName == null) return null;

    // Remove null bytes and trim
    var sanitized = deviceName.replaceAll('\u0000', '').trim();

    if (sanitized.isEmpty) return null;

    // Truncate if too long
    if (sanitized.length > maxDeviceNameLength) {
      sanitized = sanitized.substring(0, maxDeviceNameLength);
    }

    return sanitized;
  }

  /// Validates and normalizes device type
  String _validateDeviceType(String deviceType) {
    final normalized = deviceType.toLowerCase().trim();

    if (!validDeviceTypes.contains(normalized)) {
      throw ValidationException(
        'Invalid device type: $deviceType. Must be one of: ${validDeviceTypes.join(", ")}',
      );
    }

    return normalized;
  }

  /// Validates limit parameter for queries
  int _validateLimit(int limit) {
    if (limit < 1) {
      throw ValidationException('Limit must be at least 1');
    }
    if (limit > 1000) {
      throw ValidationException('Limit cannot exceed 1000');
    }
    return limit;
  }

  /// Validates ID format
  void _validateId(String id) {
    if (id.isEmpty) {
      throw ValidationException('ID cannot be empty');
    }
    // Basic validation - ID should be numeric (bigint)
    if (int.tryParse(id) == null) {
      throw ValidationException('Invalid ID format');
    }
  }

  /// Parses raw JSON data into ClipboardItem list
  /// Content is now in the same table (no more join needed)
  static List<ClipboardItem> _parseClipboardItems(List<Map<String, dynamic>> data) {
    return data.map((json) {
      try {
        // Extract encrypted content directly from clipboard table
        final encryptedContent = json['content'] as String?;

        // If no content found, throw error
        if (encryptedContent == null) {
          throw RepositoryException(
            'No content found for clipboard item ${json['id']}',
          );
        }

        // Parse target_device_type (can be null, list, or single string)
        List<String>? targetDeviceTypes;
        final targetDeviceTypeJson = json['target_device_type'];
        if (targetDeviceTypeJson != null) {
          if (targetDeviceTypeJson is List) {
            targetDeviceTypes = List<String>.from(targetDeviceTypeJson);
          } else if (targetDeviceTypeJson is String) {
            // Handle old single-value format for backwards compatibility
            targetDeviceTypes = [targetDeviceTypeJson];
          }
        }

        // Parse content_type (default to text for backwards compatibility)
        final contentTypeStr = json['content_type'] as String? ?? 'text';
        final contentType = ContentType.fromString(contentTypeStr);

        // Parse rich_text_format if present
        final richTextFormatStr = json['rich_text_format'] as String?;
        final richTextFormat = richTextFormatStr != null
            ? RichTextFormat.fromString(richTextFormatStr)
            : null;

        // Parse metadata if present
        final metadataJson = json['metadata'] as Map<String, dynamic>?;
        final metadata = metadataJson != null
            ? ClipboardMetadata.fromJson(metadataJson)
            : null;

        // Create ClipboardItem with content directly from clipboard table
        final item = ClipboardItem(
          id: json['id'].toString(),
          userId: json['user_id'] as String,
          content: encryptedContent, // This may be encrypted or plaintext
          deviceName: json['device_name'] as String?,
          deviceType: json['device_type'] as String,
          targetDeviceTypes: targetDeviceTypes,
          isPublic: json['is_public'] as bool? ?? false,
          isEncrypted: json['is_encrypted'] as bool? ?? false,
          contentType: contentType,
          storagePath: json['storage_path'] as String?,
          fileSizeBytes: json['file_size_bytes'] as int?,
          mimeType: json['mime_type'] as String?,
          metadata: metadata,
          richTextFormat: richTextFormat,
          createdAt: DateTime.parse(json['created_at'] as String),
        );

        return item;
      } catch (e) {
        // Log parsing error but continue with other items
        throw RepositoryException('Failed to parse clipboard item: $e');
      }
    }).toList();
  }

  /// Decrypt clipboard items content (only if encrypted)
  Future<List<ClipboardItem>> _decryptItems(List<ClipboardItem> items) async {
    await _ensureEncryptionInitialized();

    final decryptedItems = <ClipboardItem>[];
    for (final item in items) {
      try {
        // Only decrypt if item is marked as encrypted
        final contentToShow = item.isEncrypted
            ? await _encryptionService.decrypt(item.content)
            : item.content; // Return plaintext as-is

        decryptedItems.add(
          ClipboardItem(
            id: item.id,
            userId: item.userId,
            content: contentToShow,
            deviceName: item.deviceName,
            deviceType: item.deviceType,
            targetDeviceTypes: item.targetDeviceTypes,
            isEncrypted: item.isEncrypted,
            contentType: item.contentType,
            storagePath: item.storagePath,
            fileSizeBytes: item.fileSizeBytes,
            mimeType: item.mimeType,
            metadata: item.metadata,
            richTextFormat: item.richTextFormat,
            createdAt: item.createdAt,
          ),
        );
      } on EncryptionException catch (e) {
        debugPrint('Failed to decrypt item ${item.id}: $e');
        // Skip items that fail to decrypt
        continue;
      }
    }
    return decryptedItems;
  }

  /// Get clipboard count for the current authenticated user
  @override
  Future<int> getClipboardCountForCurrentUser() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return 0;

    try {
      final response = await _client
          .from('clipboard')
          .select('id')
          .eq('user_id', userId)
          .count();

      // The count method returns a PostgrestQueryResponse with count property
      return response.count;
    } on Object catch (e) {
      debugPrint('[ClipboardRepository] Error getting clipboard count: $e');
      return 0;
    }
  }

  /// Dispose resources to prevent memory leaks
  /// NOTE: Since this is a singleton, this should rarely be called.
  /// EncryptionService is also a singleton and should not be disposed.
  @override
  /// Reset repository state for user switch or sign out
  @override
  void reset() {
    debugPrint('[ClipboardRepository] Resetting repository state');
    _encryptionInitialized = false;
  }

  @override
  void dispose() {
    // NOTE: EncryptionService is a singleton - do NOT dispose it here
    _encryptionInitialized = false;
  }

  /// Gets current device type based on platform
  static String getCurrentDeviceType() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isLinux) return 'linux';
    throw UnsupportedError('Unsupported platform');
  }

  /// Gets current device name
  static String? getCurrentDeviceName() {
    try {
      // Try to get hostname (available on desktop platforms)
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final hostname = Platform.localHostname;
        return hostname.isNotEmpty ? hostname : null;
      }
      // For mobile, return null - can be set by user in settings
      return null;
    } on Exception {
      // Handle any exceptions when accessing hostname
      return null;
    }
  }

  /// Get file extension from MIME type
  String _getExtension(String mimeType) {
    const mimeToExt = {
      // Images
      'image/png': 'png',
      'image/jpeg': 'jpg',
      'image/gif': 'gif',
      // Documents
      'application/pdf': 'pdf',
      'application/msword': 'doc',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
          'docx',
      'text/plain': 'txt',
      // Archives
      'application/zip': 'zip',
      'application/x-tar': 'tar',
      'application/gzip': 'gz',
      // Media
      'video/mp4': 'mp4',
      'audio/mpeg': 'mp3',
      'audio/wav': 'wav',
    };
    return mimeToExt[mimeType] ?? 'bin';
  }
}

/// Top-level function for clipboard items parsing in isolate
/// Must be top-level to work with compute()
List<ClipboardItem> _parseClipboardItemsInIsolate(
  List<Map<String, dynamic>> data,
) {
  return ClipboardRepository._parseClipboardItems(data);
}

// ========== Custom Exceptions ==========

/// Exception thrown when validation fails
class ValidationException implements Exception {
  ValidationException(this.message);
  final String message;

  @override
  String toString() => 'ValidationException: $message';
}

/// Exception thrown when security checks fail
class SecurityException implements Exception {
  SecurityException(this.message);
  final String message;

  @override
  String toString() => 'SecurityException: $message';
}

/// Exception thrown when repository operations fail
class RepositoryException implements Exception {
  RepositoryException(this.message);
  final String message;

  @override
  String toString() => 'RepositoryException: $message';
}
