import 'dart:typed_data';

import '../models/clipboard_item.dart';

export 'impl/clipboard_repository.dart';

/// Abstract interface for clipboard data operations
abstract class IClipboardRepository {
  /// Insert a new clipboard item and return it with generated ID
  Future<ClipboardItem> insert(ClipboardItem item);

  /// Insert an image clipboard item
  ///
  /// Uploads image to Supabase Storage and creates DB record with storage_path
  /// Images are NOT encrypted (too large, would exceed 10MB limit after base64)
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
  });

  /// Insert a rich text clipboard item (HTML or Markdown)
  ///
  /// Encrypts content and stores in DB with rich_text_format
  Future<ClipboardItem> insertRichText({
    required String userId,
    required String deviceType,
    required String? deviceName,
    required String content,
    required RichTextFormat format,
  });

  /// Download file bytes from Supabase Storage
  ///
  /// Returns null if storage_path is null or download fails
  Future<Uint8List?> downloadFile(ClipboardItem item);

  /// Search clipboard history using lightweight local search
  ///
  /// Fast in-memory search with case-insensitive substring matching
  /// Searches content, device name, and mime type fields
  /// Returns empty list if query is empty
  Future<List<ClipboardItem>> searchHistory(String query, {int limit = 15});

  /// Watch clipboard history with real-time updates
  Stream<List<ClipboardItem>> watchHistory({int limit = 15});

  /// Get clipboard history (one-time fetch)
  Future<List<ClipboardItem>> getHistory({int limit = 15});

  /// Delete a clipboard item by ID
  Future<void> delete(String id);

  /// Clean up old clipboard items, keeping only the most recent [keepCount] items
  Future<void> cleanupOldItems({int keepCount = 15});

  /// Get clipboard count for the current authenticated user
  Future<int> getClipboardCountForCurrentUser();

  /// Reset repository state for user switch or sign out
  /// Call this when user logs out or switches accounts
  void reset();

  /// Dispose resources to prevent memory leaks
  void dispose();
}
