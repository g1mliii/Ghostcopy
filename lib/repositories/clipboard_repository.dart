import 'package:flutter/foundation.dart';

import '../models/clipboard_item.dart';
import '../models/exceptions.dart';

export 'impl/clipboard_repository.dart';

/// Abstract interface for clipboard data operations
abstract class IClipboardRepository {
  /// Number of items in the most recent history load that could not be
  /// decrypted, i.e. rows stored with is_encrypted = true that the local
  /// passphrase does not open.
  ///
  /// Such items are omitted from the returned list, so without this signal a
  /// user who signs in on a new device - or whose passphrase does not match -
  /// simply sees an empty history with no explanation. The UI uses this to
  /// prompt for the passphrase instead.
  ValueListenable<int> get undecryptableItemCount;

  /// Insert a new clipboard item and return it with generated ID
  Future<ClipboardItem> insert(ClipboardItem item);

  /// Insert a file clipboard item (supports all file types under 10MB)
  ///
  /// Uploads file to Supabase Storage and creates DB record with storage_path
  /// Bytes are encrypted before upload when a passphrase is set - encrypting
  /// raw bytes costs a flat 32 bytes, so the 10MB limit is unaffected (the old
  /// "too large after base64" reasoning applied only to the base64 path)
  /// Preserves original filename in metadata
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
  });

  /// Fetch a single clipboard item by id, decrypted, or null if it is gone.
  ///
  /// For the notification-tap and deep-link paths, which know exactly which
  /// clip they want. They used to pull a page of history and scan it.
  Future<ClipboardItem?> getById(String id);

  /// Insert an image clipboard item
  ///
  /// Convenience wrapper around insertFile for images
  /// Uploads image to Supabase Storage and creates DB record with storage_path
  /// Bytes are encrypted before upload when a passphrase is set - see insertFile
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
    List<String>? targetDeviceTypes,
  });

  /// Download file bytes from Supabase Storage
  ///
  /// Returns null if storage_path is null or download fails
  Future<Uint8List?> downloadFile(ClipboardItem item);

  /// A small preview of [item]'s image, for lists and tiles.
  ///
  /// Separate from [downloadFile] on purpose, and never a substitute for it:
  /// save, share, drag-out and copy must always take the real image, and
  /// keeping the two on different methods is what stops a thumbnail being
  /// shipped in its place. Returns null when there is nothing to preview.
  ///
  /// Cached on disk between launches, so this is a file read and a small
  /// decode rather than the full-size decrypt-and-decode it replaces.
  Future<Uint8List?> loadThumbnail(ClipboardItem item);

  /// Search clipboard history using lightweight local search
  ///
  /// Fast in-memory search with case-insensitive substring matching
  /// Searches content, device name, and mime type fields
  /// Returns empty list if query is empty
  Future<List<ClipboardItem>> searchHistory(String query, {int limit = 15});

  /// Watch clipboard history with real-time updates
  Stream<List<ClipboardItem>> watchHistory({int limit = 15});

  /// Read only the newest row ID, without fetching or decrypting its content.
  Future<String?> getLatestItemId();

  /// Get clipboard history (one-time fetch)
  Future<List<ClipboardItem>> getHistory({int limit = 15});

  /// Delete a clipboard item by ID
  Future<void> delete(String id);

  /// Clean up old clipboard items, keeping only the most recent [keepCount] items
  Future<void> cleanupOldItems({int keepCount = 15});

  /// Get clipboard count for the current authenticated user.
  /// Throws [RepositoryException] if the count cannot be retrieved.
  Future<int> getClipboardCountForCurrentUser();

  /// Reset repository state for user switch or sign out
  /// Call this when user logs out or switches accounts
  void reset();

  /// Dispose resources to prevent memory leaks
  void dispose();
}
