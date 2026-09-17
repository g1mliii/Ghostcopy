import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/clipboard_item.dart';
import '../repositories/clipboard_repository.dart';
import 'compression_service.dart';

/// Interface for widget data management and sync
abstract class IWidgetService {
  Future<void> initialize();
  Future<void> clearWidgetData();
  Future<void> updateWidgetData(List<ClipboardItem> items);
  Future<void> refreshWidget();
  void dispose();
}

/// Service to manage home screen widget data and sync.
///
/// Singleton pattern to ensure only one instance exists.
/// Handles:
/// - Widget data synchronization (text, images, rich text)
/// - Thumbnail caching (40x40px JPEG @ 80% quality)
/// - Method channel communication to native widget code
///
/// Memory Management:
/// - Disposes method channel handler in dispose()
/// - Clears thumbnail cache on disposal
/// - Does not hold onto large image data
/// - Uses lazy initialization for expensive resources
class WidgetService implements IWidgetService {
  // Constructors
  factory WidgetService() => _instance;

  WidgetService._internal();

  // Singleton instance
  static final WidgetService _instance = WidgetService._internal();

  // Compiled once: the widget refresh strips every rich-text clip it ships.
  static final _htmlTag = RegExp('<[^>]*>');
  static final _markdownMarks = RegExp(r'[*_~`#\[\]()]+');

  // Method channel for native widget communication
  static const _channel = MethodChannel('com.ghostcopy/widget');

  /// Clips the widget displays, and therefore the only ones whose thumbnails
  /// are worth keeping on disk.
  static const int _maxWidgetItems = 5;

  // State
  bool _initialized = false;
  bool _disposed = false;

  // Cache directory path (lazy loaded)
  String? _widgetCachePath;

  // Reference to clipboard repository (nullable for re-initialization)
  IClipboardRepository? _clipboardRepository;

  // Compression service for thumbnail generation
  ICompressionService? _compressionService;

  /// Initialize the widget service and set up method channel handlers
  @override
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[WidgetService] Already initialized, skipping');
      return;
    }

    // P7 FIX: Allow re-initialization after dispose by resetting state
    if (_disposed) {
      debugPrint(
        '[WidgetService] Resetting disposed state for re-initialization',
      );
      _disposed = false;
      _widgetCachePath = null;
      _clipboardRepository = null; // Reset so it's re-assigned below
    }

    try {
      // Skip initialization on unsupported platforms (desktop)
      if (!_isMobilePlatform()) {
        debugPrint(
          '[WidgetService] Platform not supported, skipping initialization',
        );
        _initialized = true;
        return;
      }

      // Get repository and compression service instances
      _clipboardRepository = ClipboardRepository.instance;
      _compressionService = CompressionService.instance;

      // Set up method call handler for widget refresh requests
      _channel.setMethodCallHandler(_handleMethodCall);

      _initialized = true;
      debugPrint('[WidgetService] ✅ Initialized');
    } catch (e) {
      debugPrint('[WidgetService] ❌ Failed to initialize: $e');
      rethrow;
    }
  }

  /// Handle method calls from native widget code
  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (_disposed) {
      debugPrint(
        '[WidgetService] Ignoring method call after disposal: ${call.method}',
      );
      throw PlatformException(
        code: 'DISPOSED',
        message: 'WidgetService has been disposed',
      );
    }

    switch (call.method) {
      case 'refreshWidget':
        try {
          await refreshWidget();
          return {'success': true};
        } catch (e) {
          debugPrint('[WidgetService] Error refreshing widget: $e');
          throw PlatformException(
            code: 'REFRESH_ERROR',
            message: 'Failed to refresh widget: $e',
          );
        }
      default:
        throw PlatformException(
          code: 'UNIMPLEMENTED',
          message: 'Method ${call.method} not implemented',
        );
    }
  }

  /// Clear everything the widget holds for the current account.
  ///
  /// Sign-out. The rows are plaintext previews, filenames and device names, so
  /// leaving them shows the previous account's clips to whoever signs in next
  /// - the same reason the thumbnails are cleared alongside them.
  @override
  Future<void> clearWidgetData() async {
    if (_isMobilePlatform()) {
      try {
        await _channel.invokeMethod('clearWidgetData');
      } on PlatformException catch (e) {
        debugPrint('[WidgetService] ⚠ Failed to clear widget data: $e');
      }
    }

    await clearThumbnailCache();
  }

  /// Update widget with latest clipboard data
  ///
  /// Prepares widget data (previews, thumbnails) and sends to native code
  @override
  Future<void> updateWidgetData(List<ClipboardItem> items) async {
    if (!_initialized || _disposed) {
      debugPrint(
        '[WidgetService] Not initialized or disposed, skipping update',
      );
      return;
    }

    if (!_isMobilePlatform()) {
      return;
    }

    try {
      final visible = items.take(_maxWidgetItems).toList();
      final widgetData = await _prepareWidgetData(visible);

      // Drop thumbnails for clips the widget no longer shows. Nothing used to
      // delete from this directory - not on clip deletion, not on sign-out -
      // so every image that ever reached the widget left a permanent file, and
      // encrypted clips left a permanently decrypted one.
      unawaited(_pruneThumbnails(visible));

      await _channel.invokeMethod('updateWidget', {
        'items': widgetData,
        'lastUpdated': DateTime.now().millisecondsSinceEpoch,
      });

      debugPrint(
        '[WidgetService] ✅ Updated widget with ${widgetData.length} items',
      );
    } on Exception catch (e) {
      debugPrint('[WidgetService] ❌ Failed to update widget: $e');
    }
  }

  /// Manually refresh widget by fetching latest items from Supabase
  ///
  /// Called when user taps refresh button on widget
  @override
  Future<void> refreshWidget() async {
    if (!_initialized || _disposed) {
      debugPrint(
        '[WidgetService] Not initialized or disposed, skipping refresh',
      );
      return;
    }

    try {
      final repo = _clipboardRepository;
      if (repo == null) {
        debugPrint('[WidgetService] Repository not initialized');
        return;
      }
      final items = await repo.getHistory(limit: _maxWidgetItems);

      // Update widget with new data
      await updateWidgetData(items);

      debugPrint(
        '[WidgetService] ✅ Widget refreshed with ${items.length} items',
      );
    } on Exception catch (e) {
      debugPrint('[WidgetService] ❌ Failed to refresh widget: $e');
    }
  }

  /// Prepare widget-specific data from clipboard items
  ///
  /// Generates previews, caches thumbnails, and returns formatted data
  Future<List<Map<String, dynamic>>> _prepareWidgetData(
    List<ClipboardItem> items,
  ) async {
    // Thumbnails are fetched together rather than one after another: each miss
    // is an R2 download plus a compression pass, and awaiting them in sequence
    // made a five-image widget refresh five serial round-trips on a mobile
    // connection. Order is preserved because Future.wait preserves it.
    final thumbnailPaths = await Future.wait(
      items.map((item) async {
        if (!item.isImage) return null;
        try {
          return await _cacheThumbnailForWidget(item);
        } on Exception catch (e) {
          debugPrint(
            '[WidgetService] Failed to cache thumbnail for ${item.id}: $e',
          );
          // Continue without thumbnail - widget will show placeholder
          return null;
        }
      }),
    );

    final widgetItems = <Map<String, dynamic>>[];

    for (final (index, item) in items.indexed) {
      final thumbnailPath = thumbnailPaths[index];

      widgetItems.add({
        'id': item.id,
        'contentType': item.contentType.value,
        'contentPreview': _generatePreview(item),
        'thumbnailPath': thumbnailPath,
        'deviceType': item.deviceType,
        'createdAt': item.createdAt.toIso8601String(),
        'isEncrypted': item.isEncrypted,
        'isFile': item.isFile,
        'isImage': item.isImage,
        'displaySize': item.displaySize,
        'filename': item.metadata?.originalFilename,
      });
    }

    return widgetItems;
  }

  /// Generate widget preview text from clipboard item
  ///
  /// Rules:
  /// - Text: First 50 chars + "..." if truncated
  /// - Image: "Image (250KB)" with no preview text
  /// - Rich text (HTML/Markdown): Strip tags, first 40 chars
  /// - Encrypted: "🔒 Encrypted content (tap to view)"
  String _generatePreview(ClipboardItem item) {
    const maxTextLength = 50;
    const maxRichTextLength = 40;

    if (item.isImage) {
      // Image preview shows file size
      return 'Image (${item.displaySize})';
    } else if (item.isFile) {
      // File preview shows filename
      return item.metadata?.originalFilename ?? 'File (${item.displaySize})';
    } else if (item.isEncrypted) {
      // Encrypted content shows lock icon
      return '🔒 Encrypted content (tap to view)';
    } else if (item.isRichText) {
      // Strip HTML/Markdown tags and truncate
      // Strip only the head of the clip. Content runs to 100KB and only
      // maxRichTextLength characters survive, so a 4x margin over that is more
      // than enough slack for the tags the strip removes.
      final stripped = _stripHtmlMarkdownTags(
        item.content.length > maxRichTextLength * 4
            ? item.content.substring(0, maxRichTextLength * 4)
            : item.content,
      );
      return stripped.length > maxRichTextLength
          ? '${stripped.substring(0, maxRichTextLength)}...'
          : stripped;
    } else {
      // Plain text: truncate to 50 chars
      return item.content.length > maxTextLength
          ? '${item.content.substring(0, maxTextLength)}...'
          : item.content;
    }
  }

  /// Strip HTML and Markdown tags from content
  ///
  /// Uses regex to remove angle bracket tags: <div>, <p>, etc.
  /// Also removes markdown syntax: ##, **, etc.
  String _stripHtmlMarkdownTags(String content) {
    // Remove HTML tags
    var stripped = content.replaceAll(_htmlTag, '');

    // Remove markdown syntax
    stripped = stripped.replaceAll(_markdownMarks, '');

    return stripped.trim();
  }

  /// Cache image thumbnail for widget
  ///
  /// Downloads image from storage, uses CompressionService to downsample
  /// to 40x40px JPEG @ 80% quality, and saves to local cache.
  ///
  /// Returns local file path or null if caching failed
  Future<String?> _cacheThumbnailForWidget(ClipboardItem item) async {
    if (!item.isImage) return null;

    try {
      final cacheDir = await _getWidgetCacheDir();
      final thumbnailFile = File('$cacheDir/${item.id}.jpg');

      // Reuse existing thumbnail for immutable clipboard item IDs.
      if (thumbnailFile.existsSync()) {
        final stat = thumbnailFile.statSync();
        if (stat.size > 0) {
          debugPrint(
            '[WidgetService] Reusing cached thumbnail: ${thumbnailFile.path}',
          );
          return thumbnailFile.path;
        }
      }

      // Download image from storage
      final repo = _clipboardRepository;
      if (repo == null) {
        debugPrint('[WidgetService] Repository not initialized for thumbnail');
        return null;
      }
      final bytes = await repo.downloadFile(item);
      if (bytes == null) {
        debugPrint('[WidgetService] No image data for ${item.id}');
        return null;
      }

      debugPrint(
        '[WidgetService] Downloaded image ${item.id}: ${bytes.lengthInBytes} bytes',
      );

      // Use CompressionService for thumbnail generation
      final compression = _compressionService;
      if (compression == null) {
        debugPrint('[WidgetService] CompressionService not initialized');
        return null;
      }

      final result = await compression.compressImage(
        bytes,
        item.mimeType ?? 'image/jpeg',
        maxDimension: 40,
        jpegQuality: 80,
      );

      debugPrint(
        '[WidgetService] Thumbnail compressed: '
        '${bytes.lengthInBytes} → ${result.compressedSize} bytes',
      );

      // Save to cache
      await thumbnailFile.writeAsBytes(result.bytes);

      debugPrint('[WidgetService] Cached thumbnail: ${thumbnailFile.path}');

      return thumbnailFile.path;
    } on Exception catch (e) {
      debugPrint(
        '[WidgetService] Failed to cache thumbnail for ${item.id}: $e',
      );
      return null;
    }
  }

  /// Delete cached thumbnails that no longer back a visible widget item.
  ///
  /// Best effort: a thumbnail that survives a failed sweep is re-checked on the
  /// next update, and a missing one is simply regenerated.
  Future<void> _pruneThumbnails(List<ClipboardItem> visible) async {
    try {
      final cacheDir = await _getWidgetCacheDir();
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) return;

      final keep = visible.map((item) => '${item.id}.jpg').toSet();
      var removed = 0;

      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.endsWith('.jpg') || keep.contains(name)) continue;

        try {
          await entity.delete();
          removed++;
        } on FileSystemException {
          // Another process may hold it; it will be retried next update.
        }
      }

      if (removed > 0) {
        debugPrint('[WidgetService] 🧹 Removed $removed stale thumbnail(s)');
      }
    } on Exception catch (e) {
      debugPrint('[WidgetService] ⚠ Thumbnail prune failed: $e');
    }
  }

  /// Delete every cached thumbnail.
  ///
  /// For sign-out and account switches, where leaving one user's decrypted
  /// images on disk for the next user is not acceptable.
  Future<void> clearThumbnailCache() async {
    try {
      final cacheDir = await _getWidgetCacheDir();
      final dir = Directory(cacheDir);
      if (!dir.existsSync()) return;

      await dir.delete(recursive: true);
      _widgetCachePath = null;
      debugPrint('[WidgetService] ✓ Thumbnail cache cleared');
    } on Exception catch (e) {
      debugPrint('[WidgetService] ⚠ Failed to clear thumbnail cache: $e');
    }
  }

  /// Get widget thumbnail cache directory
  ///
  /// - Android: `app.cacheDir/widget_thumbnails/`
  /// - iOS: App Group container `/widget_thumbnails/`
  ///
  /// The iOS half is not cosmetic. The widget is a separate process with its
  /// own sandbox, so a thumbnail under the app's own cache directory - which
  /// is what this returned on both platforms - is unreadable from the
  /// extension. `UIImage(contentsOfFile:)` returned nil for every one of them
  /// and the widget drew a generic icon in place of each image. Only the App
  /// Group container is visible to both sides.
  Future<String> _getWidgetCacheDir() async {
    if (_widgetCachePath != null) {
      return _widgetCachePath!;
    }

    try {
      final base = await _widgetCacheBaseDir();
      final widgetCache = Directory('$base/widget_thumbnails');

      try {
        await widgetCache.create(recursive: true);
        debugPrint(
          '[WidgetService] Created widget cache directory: ${widgetCache.path}',
        );
      } on FileSystemException {
        // Directory already exists, that's fine
      }

      _widgetCachePath = widgetCache.path;
      return widgetCache.path;
    } on Exception catch (e) {
      debugPrint('[WidgetService] Failed to get cache directory: $e');
      rethrow;
    }
  }

  /// Root the thumbnail cache is created under.
  ///
  /// Falls back to the app's own cache directory if the App Group lookup
  /// fails: thumbnails stop reaching the widget, which degrades to icons, but
  /// the rest of the refresh still works rather than throwing.
  Future<String> _widgetCacheBaseDir() async {
    if (Platform.isIOS) {
      try {
        final containerPath = await _channel.invokeMethod<String>(
          'getAppGroupContainerPath',
        );
        if (containerPath != null && containerPath.isNotEmpty) {
          return containerPath;
        }
        debugPrint(
          '[WidgetService] ⚠ No App Group container; '
          'widget image thumbnails will not render',
        );
      } on PlatformException catch (e) {
        debugPrint('[WidgetService] ⚠ App Group lookup failed: $e');
      }
    }

    final cacheDir = await getApplicationCacheDirectory();
    return cacheDir.path;
  }

  /// Dispose of widget service and clean up resources
  ///
  /// Memory Cleanup:
  /// - Removes method channel handler (prevents memory leaks)
  /// - Resets initialization flag
  /// - Sets disposed flag to prevent re-initialization
  @override
  void dispose() {
    if (_disposed) {
      debugPrint('[WidgetService] Already disposed, skipping');
      return;
    }

    try {
      // Remove method channel handler to prevent memory leaks
      _channel.setMethodCallHandler(null);

      _disposed = true;
      _initialized = false;

      debugPrint('[WidgetService] ✅ Disposed');
    } on Exception catch (e) {
      debugPrint('[WidgetService] Error during dispose: $e');
    }
  }

  /// Whether this platform has a home screen widget (Android and iOS only).
  ///
  /// The kIsWeb guard comes first because dart:io's Platform THROWS on web, and
  /// initialize() rethrows - so reaching this on web took the app down rather
  /// than skipping a feature web does not have. Renamed from _isMobileOrWeb,
  /// which claimed support this never had.
  bool _isMobilePlatform() {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }
}
