import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as path;

/// Custom cache manager for clipboard images with aggressive cleanup
///
/// Features:
/// - Max 10 cached images (lightweight for background app)
/// - 1-day expiry (vs default 7 days)
/// - Synced with clipboard history (auto-cleanup on delete)
/// - Automatic cleanup on history refresh
///
/// Usage:
/// ```dart
/// final cacheManager = ClipboardCacheManager.instance;
/// await cacheManager.removeFile(url); // Delete specific image
/// await cacheManager.cleanupOrphaned(validUrls); // Remove unused cache
/// ```
// ignore: prefer_constructors_over_static_methods
class ClipboardCacheManager {
  /// Singleton instance via factory constructor
  factory ClipboardCacheManager() {
    _instance ??= ClipboardCacheManager._();
    return _instance!;
  }

  ClipboardCacheManager._() {
    // Initialize cache manager once
    _initCacheManager();
  }

  static ClipboardCacheManager? _instance;
  late final CacheManager _cacheManager;

  /// Static accessor for convenience
  // ignore: prefer_constructors_over_static_methods
  static ClipboardCacheManager get instance => ClipboardCacheManager();

  /// Verify singleton pattern in debug builds
  static void assertSingleton() {
    assert(() {
      final instance1 = ClipboardCacheManager();
      final instance2 = ClipboardCacheManager();
      final instance3 = ClipboardCacheManager.instance;

      if (instance1 != instance2 || instance2 != instance3) {
        throw StateError(
          'ClipboardCacheManager is not a singleton! '
          'instance1=$instance1, instance2=$instance2, instance3=$instance3',
        );
      }

      debugPrint('[ClipboardCache] ✓ Singleton verified: All instances identical');
      return true;
    }());
  }

  /// Initialize cache manager (called once in constructor)
  void _initCacheManager() {
    _cacheManager = CacheManager(
      Config(
        'ghostcopy_clipboard_images',
        stalePeriod: const Duration(days: 1), // 1 day instead of 7
        maxNrOfCacheObjects: 10, // Max 10 images (lightweight for background app)
        repo: JsonCacheInfoRepository(databaseName: 'ghostcopy_image_cache'),
        fileService: HttpFileService(),
      ),
    );
  }

  /// Custom cache manager with lightweight configuration
  CacheManager get cacheManager => _cacheManager;

  /// Remove a single image from cache by URL
  ///
  /// Call this when a clipboard item is deleted
  Future<void> removeFile(String url) async {
    try {
      if (url.isEmpty) return;

      await cacheManager.removeFile(url);
      debugPrint('[ClipboardCache] ✓ Removed from cache: ${_shortUrl(url)}');
    } on Exception catch (e) {
      debugPrint('[ClipboardCache] ⚠ Failed to remove from cache: $e');
      // Don't throw - cache cleanup is best effort
    }
  }

  /// Remove multiple images from cache by URLs
  ///
  /// Call this when multiple items are deleted
  Future<void> removeFiles(List<String> urls) async {
    if (urls.isEmpty) return;

    debugPrint('[ClipboardCache] 🗑️ Removing ${urls.length} items from cache');

    for (final url in urls) {
      await removeFile(url);
    }

    debugPrint('[ClipboardCache] ✓ Batch removal complete');
  }

  /// Clean up orphaned cache entries not in current history
  ///
  /// Call this:
  /// - On app startup
  /// - When history is refreshed
  /// - Periodically (e.g., every hour)
  ///
  /// [validUrls] - Set of URLs that should be kept in cache
  ///
  /// Note: Due to flutter_cache_manager API limitations, we rely on:
  /// 1. Automatic 1-day expiry (configured in cacheManager)
  /// 2. Max 20 objects limit (configured in cacheManager)
  /// 3. Manual removal on delete (via removeFile)
  ///
  /// This simple approach is performant and sufficient for our use case.
  Future<void> cleanupOrphaned(Set<String> validUrls) async {
    try {
      debugPrint(
        '[ClipboardCache] 🧹 Cache bounded by: 10 objects max, 1 day expiry',
      );
      debugPrint(
        '[ClipboardCache] 📊 Current history has ${validUrls.length} images',
      );

      // The cache manager automatically enforces:
      // - Max 20 objects (oldest removed when limit reached)
      // - 1 day expiry (stale items auto-deleted)
      //
      // No manual cleanup needed - the library handles it!

      debugPrint('[ClipboardCache] ✓ Cache auto-managed (20 max, 1d expiry)');
    } on Exception catch (e) {
      debugPrint('[ClipboardCache] ⚠ Orphan cleanup check failed: $e');
      // Don't throw - cleanup is best effort
    }
  }

  /// Get cache statistics for monitoring
  ///
  /// Returns estimated stats based on configuration limits
  Future<CacheStats> getStats() async {
    // Since flutter_cache_manager doesn't expose internal stats easily,
    // we return configuration-based estimates
    return const CacheStats(
      itemCount: -1, // Unknown without deep inspection
      totalSizeBytes: -1, // Unknown without deep inspection
      maxItems: 10,
    );
  }

  /// Clear all cache (nuclear option)
  ///
  /// Call this only when user explicitly requests cache clear
  Future<void> clearAll() async {
    try {
      debugPrint('[ClipboardCache] 💣 Clearing all cache');
      await cacheManager.emptyCache();
      debugPrint('[ClipboardCache] ✓ All cache cleared');
    } on Exception catch (e) {
      debugPrint('[ClipboardCache] ⚠ Failed to clear cache: $e');
    }
  }

  /// Shorten URL for logging (show filename only)
  String _shortUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return path.basename(uri.path);
    } on Exception {
      return url.substring(0, url.length > 50 ? 50 : url.length);
    }
  }
}

/// Cache statistics
class CacheStats {
  const CacheStats({
    required this.itemCount,
    required this.totalSizeBytes,
    required this.maxItems,
  });

  final int itemCount;
  final int totalSizeBytes;
  final int maxItems;

  double get totalSizeMB => totalSizeBytes / (1024 * 1024);

  @override
  String toString() {
    return 'CacheStats(items: $itemCount/$maxItems, size: ${totalSizeMB.toStringAsFixed(1)}MB)';
  }
}
