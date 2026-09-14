import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as path;

/// Custom cache manager for clipboard images with aggressive cleanup
///
/// Features:
/// - Max [_maxCacheObjects] cached images (lightweight for background app)
/// - 1-day expiry (vs default 7 days)
/// - Synced with clipboard history (auto-cleanup on delete)
/// - Orphan removal on history refresh, via [cleanupOrphaned]
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
  late final JsonCacheInfoRepository _infoRepository;

  /// Upper bound the library enforces on its own. Named so the log lines and
  /// the stats below cannot drift from the configured value the way the old
  /// hardcoded "20" in those messages had.
  static const int _maxCacheObjects = 10;

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

      debugPrint(
        '[ClipboardCache] ✓ Singleton verified: All instances identical',
      );
      return true;
    }());
  }

  /// Initialize cache manager (called once in constructor)
  void _initCacheManager() {
    // Held as a field, not constructed inline: CacheStore keeps its repository
    // private, so this is the only handle on what the cache is actually
    // tracking - which orphan cleanup needs in order to delete anything.
    _infoRepository = JsonCacheInfoRepository(
      databaseName: 'ghostcopy_image_cache',
    );

    _cacheManager = CacheManager(
      Config(
        'ghostcopy_clipboard_images',
        stalePeriod: const Duration(days: 1), // 1 day instead of 7
        maxNrOfCacheObjects: _maxCacheObjects,
        repo: _infoRepository,
        fileService: HttpFileService(),
      ),
    );
  }

  /// Every URL the cache is currently tracking.
  ///
  /// open() is reference-counted by the repository, so calling it here shares
  /// the connection CacheStore already holds rather than opening a second one.
  Future<List<String>> _trackedUrls() async {
    await _infoRepository.open();
    final objects = await _infoRepository.getAllObjects();
    return objects.map((object) => object.url).toList();
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

  /// Remove cached images whose clipboard item is gone from history.
  ///
  /// [validUrls] is the set of URLs that should survive; everything the cache
  /// is tracking that is not in it gets dropped.
  ///
  /// This used to log three lines and delete nothing, on the reasoning that the
  /// library's size cap and expiry would get there eventually. They do not do
  /// the same job: a deleted clip's image stayed readable on disk for up to a
  /// day, and the cap only evicts once the cache is already full.
  Future<void> cleanupOrphaned(Set<String> validUrls) async {
    try {
      final orphans = (await _trackedUrls())
          .where((url) => url.isNotEmpty && !validUrls.contains(url))
          .toSet();

      if (orphans.isEmpty) {
        debugPrint('[ClipboardCache] ✓ No orphaned cache entries');
        return;
      }

      for (final url in orphans) {
        await cacheManager.removeFile(url);
      }

      debugPrint(
        '[ClipboardCache] 🧹 Removed ${orphans.length} orphaned entr'
        '${orphans.length == 1 ? 'y' : 'ies'}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardCache] ⚠ Orphan cleanup failed: $e');
      // Don't throw - cleanup is best effort
    }
  }

  /// Get cache statistics for monitoring
  ///
  /// Returns -1 counts only if the cache store cannot be read.
  Future<CacheStats> getStats() async {
    // Since flutter_cache_manager doesn't expose internal stats easily,
    // we return configuration-based estimates
    try {
      await _infoRepository.open();
      final objects = await _infoRepository.getAllObjects();
      return CacheStats(
        itemCount: objects.length,
        totalSizeBytes: objects.fold<int>(
          0,
          (sum, object) => sum + (object.length ?? 0),
        ),
        maxItems: _maxCacheObjects,
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardCache] ⚠ Could not read cache stats: $e');
      return const CacheStats(
        itemCount: -1,
        totalSizeBytes: -1,
        maxItems: _maxCacheObjects,
      );
    }
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
