import 'dart:collection';

import 'package:flutter/foundation.dart';

/// In-memory LRU cache for downloaded clipboard media (images and files).
///
/// Keyed by `storage_path`, which is stable for the life of a clip. The old
/// disk cache keyed off the object's public URL, which no longer works: the R2
/// bucket is private and every read now goes through a freshly signed URL with
/// a 5-minute TTL, so a URL key never repeats and could never hit.
///
/// Without this, media is re-downloaded from R2 on every rebuild - scrolling
/// history re-fetches the same image repeatedly, which costs egress on every
/// frame that rebuilds a tile.
///
/// Bounded by total bytes rather than entry count, since one screenshot can
/// outweigh a hundred small files. The least recently *used* entry is evicted
/// first, and everything is dropped on memory pressure.
class MediaMemoryCache {
  MediaMemoryCache._();

  static final MediaMemoryCache instance = MediaMemoryCache._();

  /// Roughly two or three full-screen screenshots. Deliberately modest: the
  /// desktop app sits in the background almost all the time.
  static const int maxBytes = 24 * 1024 * 1024;

  /// Anything above this is streamed straight through rather than cached, so a
  /// single large file cannot evict everything else.
  static const int maxEntryBytes = 8 * 1024 * 1024;

  /// Insertion-ordered so the first key is the least recently used. A hit
  /// re-inserts its key to move it to the back.
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();

  int _currentBytes = 0;

  int get currentBytes => _currentBytes;
  int get entryCount => _entries.length;

  Uint8List? get(String storagePath) {
    final hit = _entries.remove(storagePath);
    if (hit == null) return null;
    // Re-insert at the back: most recently used.
    _entries[storagePath] = hit;
    return hit;
  }

  void put(String storagePath, Uint8List bytes) {
    if (bytes.length > maxEntryBytes) {
      debugPrint(
        '[MediaCache] Skipping ${bytes.length} byte entry (over per-entry cap)',
      );
      return;
    }

    // Replacing an existing entry must not double-count its bytes.
    final existing = _entries.remove(storagePath);
    if (existing != null) _currentBytes -= existing.length;

    _entries[storagePath] = bytes;
    _currentBytes += bytes.length;

    while (_currentBytes > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final evicted = _entries.remove(oldestKey);
      _currentBytes -= evicted?.length ?? 0;
      debugPrint('[MediaCache] Evicted $oldestKey to stay under cap');
    }
  }

  /// Drop one entry, e.g. when its clip is deleted.
  void remove(String storagePath) {
    final removed = _entries.remove(storagePath);
    if (removed != null) _currentBytes -= removed.length;
  }

  /// Drop everything. Called on system memory pressure and on sign-out, since
  /// cached bytes belong to the account that downloaded them.
  void clear() {
    if (_entries.isEmpty) return;
    debugPrint(
      '[MediaCache] Cleared ${_entries.length} entries '
      '(${(_currentBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
    );
    _entries.clear();
    _currentBytes = 0;
  }
}
