import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../services/encryption_service.dart';
import '../../services/impl/encryption_service.dart';
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
class ClipboardRepository implements IClipboardRepository {
  ClipboardRepository({
    SupabaseClient? client,
    IEncryptionService? encryptionService,
  })  : _client = client ?? Supabase.instance.client,
        _encryptionService = encryptionService ?? EncryptionService();

  final SupabaseClient _client;
  final IEncryptionService _encryptionService;
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

      // Encrypt content before sending to Supabase
      final sanitizedContent = _sanitizeContent(item.content);
      final encryptedContent = await _encryptionService.encrypt(sanitizedContent);

      // Insert into clipboard table (content is now in the same table)
      // RLS policies will enforce user_id = auth.uid()
      // Cleanup happens automatically via database trigger (no client-side overhead)
      // Use .select() to get the inserted record with generated ID
      final response = await _client.from('clipboard').insert({
        'user_id': userId,
        'device_name': _sanitizeDeviceName(item.deviceName),
        'device_type': _validateDeviceType(item.deviceType),
        'target_device_type': item.targetDeviceType != null
            ? _validateDeviceType(item.targetDeviceType!)
            : null, // null = broadcast to all devices
        'content': encryptedContent, // Content is now in the same table
        'is_public': false, // Force to false for security - no public sharing
        'encryption_version': 1, // Track encryption version for future upgrades
      }).select().single();

      // Return the inserted item with generated ID
      return ClipboardItem(
        id: response['id'].toString(),
        userId: userId,
        content: item.content, // Return original unencrypted content
        deviceName: item.deviceName,
        deviceType: item.deviceType,
        targetDeviceType: item.targetDeviceType,
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
  Stream<List<ClipboardItem>> watchHistory({int limit = 50}) {
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
          .order('created_at')
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
  Future<List<ClipboardItem>> getHistory({int limit = 50}) async {
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
          .order('created_at')
          .limit(safeLimit);

      final items = _parseClipboardItems(response);
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
  Future<void> cleanupOldItems({int keepCount = 10}) async {
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

        // Delete old items individually
        for (final id in itemsToDelete) {
          await _client
              .from('clipboard')
              .delete()
              .eq('id', id)
              .eq('user_id', userId); // Defense in depth
        }

        debugPrint('Cleaned up ${itemsToDelete.length} old clipboard items');
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
  List<ClipboardItem> _parseClipboardItems(List<Map<String, dynamic>> data) {
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

        // Create ClipboardItem with content directly from clipboard table
        final item = ClipboardItem(
          id: json['id'].toString(),
          userId: json['user_id'] as String,
          content: encryptedContent, // This is still encrypted at this point
          deviceName: json['device_name'] as String?,
          deviceType: json['device_type'] as String,
          targetDeviceType: json['target_device_type'] as String?,
          isPublic: json['is_public'] as bool? ?? false,
          createdAt: DateTime.parse(json['created_at'] as String),
        );

        return item;
      } catch (e) {
        // Log parsing error but continue with other items
        throw RepositoryException('Failed to parse clipboard item: $e');
      }
    }).toList();
  }

  /// Decrypt clipboard items content
  Future<List<ClipboardItem>> _decryptItems(
    List<ClipboardItem> items,
  ) async {
    await _ensureEncryptionInitialized();

    final decryptedItems = <ClipboardItem>[];
    for (final item in items) {
      try {
        final decryptedContent = await _encryptionService.decrypt(item.content);
        decryptedItems.add(
          ClipboardItem(
            id: item.id,
            userId: item.userId,
            content: decryptedContent,
            deviceName: item.deviceName,
            deviceType: item.deviceType,
            targetDeviceType: item.targetDeviceType,
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

  /// Dispose resources to prevent memory leaks
  @override
  void dispose() {
    _encryptionService.dispose();
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
