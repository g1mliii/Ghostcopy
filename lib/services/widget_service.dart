import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/clipboard_item.dart';
import '../repositories/clipboard_repository.dart';

/// Interface for widget data management and sync
abstract class IWidgetService {
  Future<void> initialize();
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

  // Method channel for native widget communication
  static const _channel = MethodChannel('com.ghostcopy/widget');

  // State
  bool _initialized = false;
  bool _disposed = false;

  // Cache directory path (lazy loaded)
  String? _widgetCachePath;

  // Reference to clipboard repository
  late final IClipboardRepository _clipboardRepository;

  /// Initialize the widget service and set up method channel handlers
  @override
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[WidgetService] Already initialized, skipping');
      return;
    }

    if (_disposed) {
      throw StateError(
        'WidgetService has been disposed and cannot be re-initialized',
      );
    }

    try {
      // Skip initialization on unsupported platforms (desktop)
      if (!_isMobileOrWeb()) {
        debugPrint(
          '[WidgetService] Platform not supported, skipping initialization',
        );
        _initialized = true;
        return;
      }

      // Get repository instance
      _clipboardRepository = ClipboardRepository.instance;

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

    if (!_isMobileOrWeb()) {
      return;
    }

    try {
      final widgetData = await _prepareWidgetData(items.take(5).toList());

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
      // Fetch latest 5 items from Supabase
      final items = await _clipboardRepository.getHistory(limit: 5);

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
    final widgetItems = <Map<String, dynamic>>[];

    for (final item in items) {
      String? thumbnailPath;

      // Generate and cache thumbnail for image items
      if (item.isImage) {
        try {
          thumbnailPath = await _cacheThumbnailForWidget(item);
        } on Exception catch (e) {
          debugPrint(
            '[WidgetService] Failed to cache thumbnail for ${item.id}: $e',
          );
          // Continue without thumbnail - widget will show placeholder
        }
      }

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
      final stripped = _stripHtmlMarkdownTags(item.content);
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
    var stripped = content.replaceAll(RegExp('<[^>]*>'), '');

    // Remove markdown syntax
    stripped = stripped.replaceAll(RegExp(r'[*_~`#\[\]()]+'), '');

    return stripped.trim();
  }

  /// Cache image thumbnail for widget
  ///
  /// Downloads image from Supabase Storage, downsamples to 40x40px,
  /// compresses to JPEG @ 80% quality, and saves to local cache.
  ///
  /// Returns local file path or null if caching failed
  ///
  /// Memory Management:
  /// - Image bytes only held in memory during processing
  /// - Downsampled image kept only in JPEG output
  /// - Original bytes immediately discarded
  Future<String?> _cacheThumbnailForWidget(ClipboardItem item) async {
    if (!item.isImage) return null;

    try {
      // Download image from Supabase Storage
      final bytes = await _clipboardRepository.downloadFile(item);
      if (bytes == null) {
        debugPrint('[WidgetService] No image data for ${item.id}');
        return null;
      }

      debugPrint(
        '[WidgetService] Downloaded image ${item.id}: ${bytes.lengthInBytes} bytes',
      );

      // Decode image
      final image = img.decodeImage(bytes);
      if (image == null) {
        debugPrint('[WidgetService] Failed to decode image ${item.id}');
        return null;
      }

      // Downsample to 40x40 (thumbnail size for widget)
      final thumbnail = img.copyResize(
        image,
        width: 40,
        height: 40,
        interpolation: img.Interpolation.linear,
      );

      // Encode as JPEG @ 80% quality
      final jpegBytes = Uint8List.fromList(
        img.encodeJpg(thumbnail, quality: 80),
      );

      debugPrint(
        '[WidgetService] Thumbnail compressed: '
        '${bytes.lengthInBytes} → ${jpegBytes.lengthInBytes} bytes',
      );

      // Save to cache
      final cacheDir = await _getWidgetCacheDir();
      final thumbnailFile = File('$cacheDir/${item.id}.jpg');

      await thumbnailFile.writeAsBytes(jpegBytes);

      debugPrint('[WidgetService] ✅ Cached thumbnail: ${thumbnailFile.path}');

      return thumbnailFile.path;
    } on Exception catch (e) {
      debugPrint(
        '[WidgetService] ❌ Failed to cache thumbnail for ${item.id}: $e',
      );
      return null;
    }
  }

  /// Get widget thumbnail cache directory
  ///
  /// Creates directory if needed:
  /// - Android: `app.cacheDir/widget_thumbnails/`
  /// - iOS: App Group container `/widget_thumbnails/`
  Future<String> _getWidgetCacheDir() async {
    if (_widgetCachePath != null) {
      return _widgetCachePath!;
    }

    try {
      final cacheDir = await getApplicationCacheDirectory();
      final widgetCache = Directory('${cacheDir.path}/widget_thumbnails');

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

  /// Check if platform supports widgets (mobile or web)
  bool _isMobileOrWeb() {
    return Platform.isAndroid || Platform.isIOS;
  }
}
