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

    trimTo(maxBytes);
  }

  /// Drop one entry, e.g. when its clip is deleted.
  void remove(String storagePath) {
    final removed = _entries.remove(storagePath);
    if (removed != null) _currentBytes -= removed.length;
  }

  /// What survives hiding the window, in bytes.
  ///
  /// Hiding used to [clear] outright, on the reasoning that cached media is
  /// pure overhead while the app sits in the tray. Measured on Windows
  /// (`docs/windows-performance.md`), that reasoning does not hold: hidden the
  /// process sits at ~107 MB, and of that 182 MB of mapped modules, 44.8 MB is
  /// the GPU driver and 20.5 MB the Flutter engine. Dropping every cached
  /// image reclaimed about 5 MB of a number dominated by things no cache
  /// touches - and it is exactly what made an already-fetched clip slow to
  /// come back, because the disk copy is stored encrypted, so each reopen paid
  /// a read, an isolate spawn, an AES pass and a decode per thumbnail.
  ///
  /// Keeping a few megabytes of the most recently used media is a far better
  /// trade at that scale.
  static const int idleBytes = 6 * 1024 * 1024;

  /// Evict down to [budget] bytes, keeping the most recently used.
  ///
  /// The LRU order does the choosing, so what survives is what the user was
  /// last looking at - which is what they will see first on reopening.
  void trimTo(int budget) {
    final before = _currentBytes;
    while (_currentBytes > budget && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final evicted = _entries.remove(oldestKey);
      _currentBytes -= evicted?.length ?? 0;
    }
    if (before != _currentBytes) {
      debugPrint(
        '[MediaCache] Trimmed ${((before - _currentBytes) / 1024 / 1024).toStringAsFixed(1)} MB '
        'to ${(_currentBytes / 1024 / 1024).toStringAsFixed(1)} MB '
        '(${_entries.length} entries kept)',
      );
    }
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
