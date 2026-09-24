import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../models/clipboard_limits.dart';
import '../../models/exceptions.dart';
import '../../services/clipboard_cache_manager.dart';
import '../../services/encryption_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/media_disk_cache.dart';
import '../../services/media_memory_cache.dart';
import '../../services/storage_service.dart';
import '../../utils/platform_label.dart';
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

  /// User the loaded encryption state belongs to, so a sign-in as someone
  /// else re-keys instead of silently reusing the previous account's state.
  String? _encryptionUserId;

  /// Items in the last history load that could not be decrypted. See
  /// IClipboardRepository.undecryptableItemCount.
  final ValueNotifier<int> _undecryptableItemCount = ValueNotifier<int>(0);

  /// Downloads currently in progress, keyed by storage_path.
  ///
  /// Several widgets routinely ask for the same image at once - a history tile
  /// and an expanded preview, or two tiles across a rebuild. Without this they
  /// all miss the cache (nothing is in it yet) and each runs its own signed-URL
  /// request, R2 fetch and AES decrypt for identical bytes. Observed in the
  /// logs as the same object downloaded and "Decrypted to N bytes" twice,
  /// milliseconds apart, which is most of the first-load latency on mobile.
  final Map<String, Future<Uint8List?>> _inFlightDownloads =
      <String, Future<Uint8List?>>{};

  @override
  ValueListenable<int> get undecryptableItemCount => _undecryptableItemCount;

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
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw SecurityException('User must be authenticated for encryption');
    }

    // Keyed on the user, not just a bool. reset() runs on sign-OUT, but nothing
    // resets this on sign-IN - so after signing back in without restarting, a
    // bare `if (_encryptionInitialized) return;` skipped the re-key and left
    // the anonymous account's keyless state in place, showing every clip as
    // encrypted. EncryptionService.initialize() makes the same check itself;
    // this one keeps us from skipping the call that would perform it.
    if (_encryptionInitialized && _encryptionUserId == userId) return;

    await _encryptionService.initialize(userId);
    _encryptionInitialized = true;
    _encryptionUserId = userId;
  }

  @override
  Future<ClipboardItem> insert(ClipboardItem item) async {
    // Validate and sanitize input before sending to Supabase
    _validateClipboardItem(item);

    try {
      final userId = _requireOwner(item.userId, 'clipboard items');

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
        // The sanitized text, which is what was stored. Returning the raw
        // input meant the caller's echo differed from the row by whatever
        // _sanitizeContent trimmed.
        content: sanitizedContent,
        deviceName: item.deviceName,
        deviceType: item.deviceType,
        targetDeviceTypes: item.targetDeviceTypes,
        isEncrypted: isEncryptionEnabled,
        createdAt: DateTime.parse(response['created_at'] as String),
      );
    } catch (e) {
      _fail(e, 'insert clipboard item');
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
      _requireOwner(userId, 'file items');

      if (fileBytes.length > ClipboardLimits.maxFileBytes) {
        throw ValidationException(
          'File exceeds ${ClipboardLimits.maxFileLabel} limit: '
          '${fileBytes.length} bytes',
        );
      }

      // Validate content type requires storage
      if (!contentType.requiresStorage) {
        throw ValidationException(
          'Content type must require storage, got: ${contentType.value}',
        );
      }

      // Build metadata with original filename
      final metadata = <String, dynamic>{
        'width': ?width,
        'height': ?height,
        'original_filename': ?originalFilename,
      };

      // FIXED: Upload file FIRST to avoid race condition with realtime INSERT event
      // Use timestamp for storage path (doesn't need to match database ID)
      final storageId = DateTime.now().millisecondsSinceEpoch.toString();
      final filename =
          originalFilename ??
          'file.${ContentType.fromMimeType(mimeType)?.fileExtension ?? 'bin'}';

      // Store the original payload. Thumbnail resizing belongs only in the
      // image widget: exports, drag-and-drop and receiving devices must get
      // the same bytes, dimensions and format that were selected for sending.
      var uploadBytes = fileBytes;

      // Encrypt the bytes themselves before they leave the device.
      //
      // Files and images used to be stored in the clear even with a passphrase
      // set - the comment said "too large, would exceed 10MB limit after
      // base64". That is true of the base64 string path, but encrypting raw
      // bytes costs a flat 32 bytes (IV + GCM tag), so the limit is unaffected.
      // Without this, turning on end-to-end encryption protected your text and
      // left your screenshots and documents readable to anyone with R2 access.
      //
      // Initialize FIRST. isEnabled() only reports whether a key is loaded, and
      // the key is loaded by initialize(). Asking cold answers "no encryption"
      // and uploads the bytes in the clear with is_encrypted = false -
      // permanently, and with no error. insert() and insertRichText() have
      // always initialized here; these two file paths did not, so the headless
      // `--send-file` launch (Explorer's "Send with GhostCopy", which loads no
      // history and shows no UI) uploaded every file unencrypted regardless of
      // the passphrase.
      await _ensureEncryptionInitialized();
      final filesEncrypted = await _encryptionService.isEnabled();
      if (filesEncrypted) {
        uploadBytes = await _encryptionService.encryptBytes(uploadBytes);
        debugPrint(
          '[Repository] 🔒 Encrypted ${uploadBytes.length} bytes for upload',
        );
      }

      debugPrint(
        '[Repository] ↑ Uploading to storage (${uploadBytes.length} bytes): $filename',
      );

      // 1. Upload to Storage first
      final uploadResult = await _storageService.uploadFile(
        userId: userId,
        clipboardId: storageId,
        bytes: uploadBytes,
        filename: filename,
        mimeType: mimeType,
      );

      // 2. Insert to database with correct storage path (no placeholder, no UPDATE!)
      debugPrint('[Repository] ↑ Inserting database record');

      try {
        final response = await _client
            .from('clipboard')
            .insert({
              'user_id': userId,
              'device_name': _sanitizeDeviceName(deviceName),
              'device_type': _validateDeviceType(deviceType),
              'target_device_type': targetDeviceTypes
                  ?.map(_validateDeviceType)
                  .toList(), // null = broadcast to all devices
              // content is NOT NULL and used to hold a public r2.dev URL.
              // The bucket is private now, so that URL 401s and is worse than
              // useless - history search matches on content, so it made every
              // image match a search for "r2". The filename is what a user
              // would actually search for; the bytes live at storage_path.
              'content': originalFilename ?? filename,
              'content_type': contentType.value,
              'mime_type': mimeType,
              'file_size_bytes': uploadBytes.length,
              'storage_path': uploadResult.storagePath,
              if (metadata.isNotEmpty) 'metadata': metadata,
              // The R2 object is encrypted; the row's `content` (a filename)
              // is not, which is why this is not gated on content.
              'is_encrypted': filesEncrypted,
            })
            .select()
            .single();

        final clipId = response['id'].toString();

        debugPrint('[Repository] ✓ File uploaded successfully: $filename');

        return ClipboardItem(
          id: clipId,
          userId: userId,
          content: originalFilename ?? filename,
          deviceName: deviceName,
          deviceType: deviceType,
          targetDeviceTypes: targetDeviceTypes,
          contentType: contentType,
          storagePath: uploadResult.storagePath,
          isEncrypted: filesEncrypted,
          // Match the stored size, including encryption overhead when enabled.
          fileSizeBytes: uploadBytes.length,
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
      } on Exception catch (e) {
        // FIXED: Clean up orphaned storage file if database insert fails
        debugPrint(
          '[Repository] ✗ Database insert failed, cleaning up storage: $e',
        );
        try {
          await _storageService.deleteFile(uploadResult.storagePath);
          debugPrint('[Repository] ✓ Cleaned up orphaned storage file');
        } on Exception catch (deleteError) {
          debugPrint('[Repository] ⚠ Failed to clean up storage: $deleteError');
        }
        rethrow;
      }
    } catch (e) {
      _fail(e, 'insert file');
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
    List<String>? targetDeviceTypes,
  }) async {
    try {
      _requireOwner(userId, 'rich text items');

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
            // Rich text used to ignore this entirely, so choosing "send to
            // Android only" and then pasting HTML broadcast to every device.
            'target_device_type': targetDeviceTypes
                ?.map(_validateDeviceType)
                .toList(),
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
        targetDeviceTypes: targetDeviceTypes,
        contentType: contentType,
        mimeType: mimeType,
        richTextFormat: format,
        isEncrypted: isEncryptionEnabled,
        createdAt: DateTime.parse(response['created_at'] as String),
      );
    } catch (e) {
      _fail(e, 'insert rich text');
    }
  }

  @override
  Future<Uint8List?> downloadFile(ClipboardItem item) async {
    if (item.storagePath == null) {
      debugPrint('[Repository] ○ No storage path for item ${item.id}');
      return null;
    }

    final storagePath = item.storagePath!;

    // Serve from RAM when we already have the bytes. Downloads now go through
    // a freshly signed URL every time (the bucket is private), so nothing
    // upstream caches them - without this, scrolling history re-downloads the
    // same image from R2 on every rebuild and bills egress for it.
    final cached = MediaMemoryCache.instance.get(storagePath);
    if (cached != null) {
      debugPrint(
        '[Repository] ⚡ Cache hit: $storagePath (${cached.length} bytes)',
      );
      return cached;
    }

    // Join an identical request already running rather than starting a second.
    final inFlight = _inFlightDownloads[storagePath];
    if (inFlight != null) {
      debugPrint('[Repository] ⏳ Joining in-flight download: $storagePath');
      return inFlight;
    }

    // Registered before any await so a concurrent caller sees it immediately.
    // The disk lookup lives inside _resolveBytes so that it, too, is covered
    // by the in-flight join - otherwise two tiles rebuilding at once would
    // both read and decrypt the same file.
    final future = _resolveBytes(item, storagePath);
    _inFlightDownloads[storagePath] = future;
    try {
      return await future;
    } finally {
      // remove() hands back the Future we just awaited; discarding it here is
      // the point of the cleanup.
      // ignore: unawaited_futures
      _inFlightDownloads.remove(storagePath);
    }
  }

  /// Disk cache first, network second. Returns plaintext bytes either way.
  Future<Uint8List?> _resolveBytes(
    ClipboardItem item,
    String storagePath,
  ) async {
    final cached = await MediaDiskCache.instance.get(storagePath);
    if (cached != null) {
      debugPrint(
        '[Repository] 💾 Disk cache hit: $storagePath (${cached.length} bytes)',
      );
      final bytes = await _decryptDownloaded(item, cached);
      if (bytes != null) MediaMemoryCache.instance.put(storagePath, bytes);
      return bytes;
    }
    return _downloadAndDecrypt(item, storagePath);
  }

  Future<Uint8List?> _downloadAndDecrypt(
    ClipboardItem item,
    String storagePath,
  ) async {
    try {
      debugPrint('[Repository] ↓ Downloading: $storagePath');

      final raw = await _storageService.downloadFile(storagePath);

      debugPrint('[Repository] ✓ Downloaded: ${raw.length} bytes');

      // Persist the bytes EXACTLY as received - still encrypted when the clip
      // is encrypted - so a restart does not pay for this download again.
      // Fire and forget: a cache write must never delay showing the image.
      unawaited(MediaDiskCache.instance.put(storagePath, raw));

      final bytes = await _decryptDownloaded(item, raw);
      if (bytes == null) return null;

      // Cache the PLAINTEXT in RAM: that cache is in-process and cleared on
      // hide, sign-out and memory pressure, so re-running AES on every hit
      // would be pure waste. The disk copy above stays encrypted.
      MediaMemoryCache.instance.put(storagePath, bytes);

      return bytes;
    } on Exception catch (e) {
      debugPrint('[Repository] ✗ Download failed: $e');
      return null;
    }
  }

  /// Turn raw stored bytes into plaintext.
  ///
  /// Decrypts only when the row says the object is encrypted. Objects uploaded
  /// before file encryption existed are stored in the clear and carry
  /// is_encrypted = false, so they pass straight through - this must stay keyed
  /// on the flag rather than on whether a passphrase is set.
  Future<Uint8List?> _decryptDownloaded(
    ClipboardItem item,
    Uint8List raw,
  ) async {
    if (!item.isEncrypted) return raw;

    await _ensureEncryptionInitialized();
    if (!await _encryptionService.isEnabled()) {
      debugPrint(
        '[Repository] 🔒 ${item.storagePath} is encrypted but no '
        'passphrase is set on this device',
      );
      return null;
    }
    final bytes = await _encryptionService.decryptBytes(raw);
    debugPrint('[Repository] 🔓 Decrypted to ${bytes.length} bytes');
    return bytes;
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
          .where((item) => item.matchesQuery(lowerQuery))
          .take(safeLimit)
          .toList();

      debugPrint('[Repository] ✓ Found ${results.length} results locally');

      return results;
    } catch (e) {
      _fail(e, 'search history');
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
    } catch (e) {
      _fail(e, 'watch clipboard history');
    }
  }

  @override
  Future<ClipboardItem?> getById(String id) async {
    _validateId(id);

    try {
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException(
          'User must be authenticated to get a clipboard item',
        );
      }

      // One row, one decrypt. The callers that want a specific clip - a
      // notification tap, a deep link - used to fetch a page of history and
      // scan it, which meant up to 100 rows off the network and 100 AES
      // decrypts to serve a single clip on a latency-critical path.
      final response = await _client
          .from('clipboard')
          .select()
          .eq('id', id)
          .eq('user_id', userId) // Explicit filter for defense in depth
          .maybeSingle();

      if (response == null) return null;

      final items = await _parseClipboardItemsAsync([response]);
      if (items.isEmpty) return null;

      final decrypted = await _decryptItems(items);
      return decrypted.isEmpty ? null : decrypted.first;
    } catch (e) {
      _fail(e, 'get clipboard item');
    }
  }

  @override
  Future<String?> getLatestItemId() async {
    try {
      final userId = _client.auth.currentUser?.id;
      if (userId == null) {
        throw SecurityException('User must be authenticated to poll clipboard');
      }
      final row = await _client
          .from('clipboard')
          .select('id')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(1)
          .maybeSingle();
      return row?['id'].toString();
    } catch (e) {
      _fail(e, 'poll clipboard');
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

      final decryptedItems = await _decryptItems(items);

      // Both cache sweeps below delete everything outside the rows just
      // returned, so they are only meaningful for a full-history fetch. Sync
      // and widget paths poll with limit: 1 and limit: 5 on every realtime
      // event; pruning against those would empty the cache continuously and
      // re-download (and re-bill) every image. Only a successful full fetch
      // may prune - doing it after a failure would wipe the cache over a
      // dropped connection. Note this still prunes against the rows actually
      // returned (15 by default) while the server retains 20, so a clip that
      // falls off the client's list loses its cached bytes and would be
      // re-fetched if it ever came back.
      if (safeLimit >= _defaultHistoryLimit) {
        // Clean up orphaned cache entries (async, don't await)
        _cleanupOrphanedCache(decryptedItems);

        // Drop disk-cached media for clips that no longer exist.
        unawaited(
          MediaDiskCache.instance.prune(
            decryptedItems
                .map((i) => i.storagePath)
                .whereType<String>()
                .where((p) => p.isNotEmpty)
                .toSet(),
          ),
        );
      }

      return decryptedItems;
    } catch (e) {
      _fail(e, 'get clipboard history');
    }
  }

  /// Clean up orphaned cache entries in background
  ///
  /// Removes cached images that are no longer in visible history
  void _cleanupOrphanedCache(List<ClipboardItem> currentHistory) {
    // Run in background, don't block history fetch
    Future(() async {
      try {
        // Get URLs of all images in current history
        final validUrls = currentHistory
            .where((item) => item.isImage && item.content.isNotEmpty)
            .map((item) => item.content)
            .toSet();

        // Clean up cache entries not in current history
        await ClipboardCacheManager.instance.cleanupOrphaned(validUrls);
      } on Exception catch (e) {
        debugPrint('[Repository] ⚠ Background cache cleanup failed: $e');
        // Swallow exception - cache cleanup is best effort
      }
    });
  }

  /// Parse clipboard items with optional isolate for large responses
  Future<List<ClipboardItem>> _parseClipboardItemsAsync(
    List<Map<String, dynamic>> data,
  ) async {
    // For small/medium responses (<100 items), parse synchronously (Fix #23)
    // Isolate overhead makes parse slower for typical payloads
    if (data.length < 100) {
      return _parseClipboardItems(data);
    }

    // For large responses (>=100 items), parse in background isolate
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

      // FIXED: Fetch item first to get URL for cache cleanup
      ClipboardItem? item;
      try {
        final response = await _client
            .from('clipboard')
            .select()
            .eq('id', id)
            .eq('user_id', userId)
            .maybeSingle();

        if (response != null) {
          item = ClipboardItem.fromJson(response);
        }
      } on Exception catch (e) {
        debugPrint('[Repository] ⚠ Failed to fetch item before delete: $e');
        // Continue with deletion even if fetch fails
      }

      // Delete with RLS enforcement
      // RLS policy ensures user can only delete their own items
      await _client
          .from('clipboard')
          .delete()
          .eq('id', id)
          .eq('user_id', userId); // Explicit filter for defense in depth

      // Drop the downloaded bytes for this clip from RAM and from disk. The
      // disk copy especially: it outlives the process, so without this a
      // deleted clip's image stayed readable in the profile directory
      // indefinitely. R2 itself is handled server-side by the
      // cleanup_storage_on_clipboard_delete trigger.
      final deletedPath = item?.storagePath;
      if (deletedPath != null && deletedPath.isNotEmpty) {
        MediaMemoryCache.instance.remove(deletedPath);
        unawaited(MediaDiskCache.instance.remove(deletedPath));
      }

      // FIXED: Remove from image cache if it's an image
      if (item != null && item.isImage && item.content.isNotEmpty) {
        try {
          await ClipboardCacheManager.instance.removeFile(item.content);
          debugPrint('[Repository] ✓ Removed from cache: ${item.id}');
        } on Exception catch (e) {
          debugPrint('[Repository] ⚠ Cache removal failed: $e');
          // Don't throw - cache cleanup is best effort
        }
      }
    } catch (e) {
      _fail(e, 'delete clipboard item');
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

      if (keepCount < 0) {
        throw ValidationException('keepCount must be non-negative');
      }
      // Bound both the response and the DELETE query string. Repeat the same
      // offset after deletion, because older rows move into that page.
      const batchSize = 100;
      while (true) {
        final batch = await _client
            .from('clipboard')
            .select('id')
            .eq('user_id', userId)
            .order('created_at', ascending: false)
            .order('id', ascending: false)
            .range(keepCount, keepCount + batchSize - 1);
        if (batch.isEmpty) break;
        await _client
            .from('clipboard')
            .delete()
            .eq('user_id', userId)
            .inFilter('id', batch.map((row) => row['id'] as Object).toList());
        if (batch.length < batchSize) break;
      }
    } catch (e) {
      _fail(e, 'cleanup old items');
    }
  }

  /// The authenticated user, verified to be [claimedUserId].
  ///
  /// Every insert path opened with its own copy of these two checks. Shared so
  /// the defense-in-depth ownership test cannot be forgotten on a new one.
  String _requireOwner(String claimedUserId, String noun) {
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null) {
      throw SecurityException('User must be authenticated to insert $noun');
    }
    if (claimedUserId != currentUserId) {
      throw SecurityException('Cannot insert $noun for another user');
    }
    return currentUserId;
  }

  /// The single error boundary for every public repository method.
  ///
  /// Each method used to end with its own copy of this ladder, and the copies
  /// had already drifted: only the upload path mapped [SocketException], so an
  /// identical network failure surfaced as a [NetworkException] on one route
  /// and a stringified [RepositoryException] on another, and only `insert`
  /// decoded the Postgres constraint codes. One place to add a new error class.
  Never _fail(Object error, String operation) {
    // Domain exceptions already say exactly what went wrong.
    if (error is Exception &&
        (error is SecurityException ||
            error is ValidationException ||
            error is EncryptionException ||
            error is NetworkException)) {
      throw error;
    }

    if (error is PostgrestException) {
      // CHECK constraint violation - the content failed a database rule.
      if (error.code == '23514') {
        throw ValidationException(
          'Content validation failed: ${error.message}',
        );
      }
      // Foreign key violation - the user_id does not exist.
      if (error.code == '23503') {
        throw SecurityException('Invalid user ID');
      }
      debugPrint('[Repository] Database error: ${error.message}');
      throw RepositoryException('Database error: ${error.message}');
    }

    if (error is SocketException) {
      throw NetworkException('Network error: Check your connection');
    }

    debugPrint('[Repository] Failed to $operation: $error');
    throw RepositoryException('Failed to $operation: $error');
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
  /// Default history page size, matching [IClipboardRepository.getHistory].
  ///
  /// A fetch of at least this many rows is treated as a full-history fetch and
  /// is the only kind allowed to prune the media caches.
  static const int _defaultHistoryLimit = 15;

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
  static List<ClipboardItem> _parseClipboardItems(
    List<Map<String, dynamic>> data,
  ) {
    // Skip rows that will not parse instead of failing the batch. The catch
    // below used to throw, which the comment said was "continue with other
    // items" but was not: one malformed row aborted the whole history load,
    // and because watchHistory() runs this inside .asyncMap, that throw became
    // a stream error that permanently killed realtime sync for the session.
    final items = <ClipboardItem>[];
    var skipped = 0;

    for (final json in data) {
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

        items.add(item);
      } on Object catch (e) {
        // Object, not Exception: a bad cast throws TypeError, which is an
        // Error - and that is the most likely way a row fails to parse.
        skipped++;
        debugPrint('[Repository] ⚠ Skipping unparseable row ${json['id']}: $e');
      }
    }

    if (skipped > 0) {
      debugPrint('[Repository] ⚠ Skipped $skipped unparseable row(s)');
    }

    return items;
  }

  /// Decrypt clipboard items content (only if encrypted)
  Future<List<ClipboardItem>> _decryptItems(List<ClipboardItem> items) async {
    // canDecrypt gates every item below, because EncryptionService.decrypt()
    // returns its input UNCHANGED when no key is loaded
    // (encryption_service.dart: `if (_keyBytes == null) return ciphertext;`)
    // rather than throwing. Without this an encrypted item on a device with no
    // passphrase sails through as "successfully decrypted" and the raw
    // `IV:ciphertext` string is rendered in history, copied to the clipboard,
    // and shown in the widget.
    //
    // Resolving it must not throw: this runs inside watchHistory()'s asyncMap,
    // so ANY throw here becomes a stream error that terminates the realtime
    // subscription for good. A momentarily-null session during a token refresh
    // is not a reason to kill sync - treat it as "cannot decrypt right now"
    // and show whatever is readable.
    var canDecrypt = false;
    try {
      await _ensureEncryptionInitialized();
      canDecrypt = await _encryptionService.isEnabled();
    } on Exception catch (e) {
      debugPrint('[Repository] Encryption unavailable for this batch: $e');
    }

    final decryptedItems = <ClipboardItem>[];
    var undecryptable = 0;

    for (final item in items) {
      try {
        // For file and image rows, is_encrypted describes the R2 OBJECT, not
        // the row's `content` - which holds the filename in the clear so it
        // stays searchable. Running decrypt() over a filename would throw and
        // silently drop every image from history the moment encryption was
        // enabled. The bytes are decrypted in downloadFile() instead.
        final isStoredObject = (item.storagePath ?? '').isNotEmpty;

        if (item.isEncrypted && !canDecrypt) {
          undecryptable++;
          // Text rows are dropped: their content IS the ciphertext and there
          // is nothing meaningful to show. File and image rows are kept - the
          // row itself holds a readable filename, size and timestamp, and only
          // the bytes in R2 are unreadable. Hiding them would make files
          // silently disappear from history the moment encryption was enabled
          // on another device.
          if (!isStoredObject) continue;
        }

        // Only decrypt if item is marked as encrypted
        final contentToShow = (item.isEncrypted && !isStoredObject)
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
      } on Exception catch (e) {
        debugPrint('Failed to decrypt item ${item.id}: $e');
        // Skip items that fail to decrypt, but COUNT them. Dropping them
        // silently meant a user signing in on a new device (or with a
        // mismatched passphrase) saw a completely empty history with no
        // explanation - the content is there, it just cannot be opened.
        //
        // Catches Exception, not just EncryptionException: decrypt() also
        // throws FormatException on a payload that is not valid base64 (a row
        // written before the current format, say). That is not an
        // EncryptionException, so it escaped this handler, propagated through
        // asyncMap and permanently killed the realtime stream - one unreadable
        // row took down sync for the whole session.
        undecryptable++;
        continue;
      }
    }

    _undecryptableItemCount.value = undecryptable;
    if (undecryptable > 0) {
      debugPrint(
        '[Repository] ⚠️ $undecryptable encrypted item(s) could not be '
        'decrypted - passphrase missing or does not match',
      );
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
    } on RepositoryException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('[ClipboardRepository] Error getting clipboard count: $e');
      // An unknown count must never authorize leaving a guest account.
      throw RepositoryException(
        'Unable to check your saved clips. Please try signing in again.',
      );
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
    _encryptionUserId = null;
    // Belongs to the signed-out user's history. Leaving it set would show the
    // next user a "N encrypted clips" prompt for clips that are not theirs.
    _undecryptableItemCount.value = 0;
    // Same reasoning for the downloaded bytes, in RAM and on disk. The disk
    // copy especially: it outlives the process, and for an account without
    // encryption enabled those bytes are plaintext media sitting in the
    // profile directory. Signing out must not leave them for the next user.
    MediaMemoryCache.instance.clear();
    unawaited(MediaDiskCache.instance.clear());
  }

  @override
  void dispose() {
    // NOTE: EncryptionService is a singleton - do NOT dispose it here
    _encryptionInitialized = false;
    _encryptionUserId = null;
    _undecryptableItemCount.value = 0;
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
  /// Resolved once. The hostname does not change while the app runs, and this
  /// is read on every send and on every realtime callback.
  static String? _cachedDeviceName;
  static bool _deviceNameResolved = false;

  /// Resolve the device name once, before anything reads it.
  ///
  /// [getCurrentDeviceName] is synchronous and read on every send and every
  /// realtime callback, but a phone's model name only comes back
  /// asynchronously. Called from main() so the answer is cached before the
  /// first send; if it is skipped the synchronous getter still returns a
  /// usable fallback, just a generic one.
  static Future<void> initializeDeviceName() async {
    if (_deviceNameResolved) return;

    // Desktop is handled by the fallback at the end: it has a hostname, which
    // is already specific to the machine and is what the user calls it, and
    // neither branch below fires there. It had its own early return, which did
    // nothing the fallback does not.
    try {
      final info = DeviceInfoPlugin();
      String? name;

      if (Platform.isAndroid) {
        final android = await info.androidInfo;
        // "Pixel 8" rather than "sdk_gphone64_arm64": model is what the user
        // would call it, and brand disambiguates identical model numbers
        // across manufacturers.
        final model = android.model.trim();
        final brand = android.brand.trim();
        final installId = await _getOrCreateInstallId();
        if (model.isNotEmpty) {
          final label = model.toLowerCase().startsWith(brand.toLowerCase())
              ? model
              : '${_capitalize(brand)} $model'.trim();
          name = '$label · ${installId.substring(0, 8)}';
        }
      } else if (Platform.isIOS) {
        final ios = await info.iosInfo;
        // Since iOS 16 `name` returns the model, not what the user called the
        // phone - that needs an Apple-granted entitlement. So "iPhone 15 Pro"
        // rather than "Subai's iPhone". Still enough to tell a phone from an
        // iPad or a simulator, which is what the unique index needs.
        final model = ios.utsname.machine.trim();
        final readable = ios.name.trim();
        final stableId =
            ios.identifierForVendor ?? await _getOrCreateInstallId();
        final shortId = stableId.replaceAll('-', '');
        final label = readable.isNotEmpty ? readable : model;
        name = label.isNotEmpty
            ? '$label · ${shortId.substring(0, min(8, shortId.length))}'
            : null;
      }

      if (name != null && name.isNotEmpty) {
        _cachedDeviceName = name;
        _deviceNameResolved = true;
        debugPrint('[Repository] Device name resolved: $name');
        return;
      }
    } on Object catch (e) {
      // Never fatal: a generic name still works, it just collides with another
      // device of the same platform.
      debugPrint('[Repository] Could not read device info: $e');
    }

    // Fall through to the platform-label fallback.
    getCurrentDeviceName();
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static const _installIdKey = 'ghostcopy_device_install_id';

  static Future<String> _getOrCreateInstallId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_installIdKey);
    if (existing != null && existing.length >= 8) return existing;

    final random = Random.secure();
    final generated = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await prefs.setString(_installIdKey, generated);
    return generated;
  }

  static String? getCurrentDeviceName() {
    if (_deviceNameResolved) return _cachedDeviceName;

    _deviceNameResolved = true;
    try {
      // Try to get hostname (available on desktop platforms)
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final hostname = Platform.localHostname;
        _cachedDeviceName = hostname.isNotEmpty ? hostname : null;
      } else {
        // Mobile has no hostname to read, and this used to return null - so
        // every clip sent from a phone landed with device_name NULL and the
        // history could not say where it came from. DeviceService already
        // falls back to this exact string when registering the device, so
        // using it here keeps the clipboard row and the devices row agreeing.
        //
        // This is a placeholder, not an identity: two phones on the same
        // platform both answer "Android Device". See the note on
        // registerCurrentDevice - the devices table is uniquely keyed on
        // (user_id, device_type, device_name), so telling them apart needs a
        // real per-device name, which is a larger change.
        _cachedDeviceName = '${platformLabel(getCurrentDeviceType())} Device';
      }
    } on Exception {
      // Handle any exceptions when accessing hostname
      _cachedDeviceName = null;
    }
    return _cachedDeviceName;
  }
}

/// Top-level function for clipboard items parsing in isolate
/// Must be top-level to work with compute()
List<ClipboardItem> _parseClipboardItemsInIsolate(
  List<Map<String, dynamic>> data,
) {
  return ClipboardRepository._parseClipboardItems(data);
}
