import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache for clipboard media (images and files) downloaded from R2.
///
/// [MediaMemoryCache] only survives while the process does - and on desktop it
/// is deliberately cleared whenever the Spotlight window loses focus, which is
/// most of the time. So every restart, and every re-open of the window, paid
/// to download the same screenshot from R2 again: slow for the user and billed
/// egress for the account. This layer sits between RAM and the network so the
/// bytes are fetched from Cloudflare exactly once.
///
/// # What is written to disk
///
/// The bytes are stored EXACTLY as they came off the wire - still encrypted
/// when the clip is encrypted - and decrypted on read. Caching plaintext would
/// be faster, but it would mean end-to-end encrypted clips sit in the clear in
/// the user's profile directory, which quietly undoes the guarantee the
/// passphrase exists to make. AES-GCM over a few megabytes is not the
/// bottleneck here; the network round trip was.
///
/// # What is kept
///
/// Two bounds, because either one alone leaves a hole:
///  - [prune] drops anything no longer in the user's history. The server keeps
///    only the 20 most recent clips per user (cleanup_old_clipboard_items_deep,
///    run daily by pg_cron) and the client lists 15, so without this the cache
///    would accumulate objects that can never be opened again.
///  - [_evictToFit] enforces [maxBytes] by least-recently-used, which covers
///    the case where prune has not run recently enough - a long offline
///    session, say.
class MediaDiskCache {
  MediaDiskCache._();

  static final MediaDiskCache instance = MediaDiskCache._();

  /// Generous next to the 24MB memory cache: this is cold storage, and the
  /// working set is bounded by the ~15 clips the app will actually show.
  static const int maxBytes = 256 * 1024 * 1024;

  /// Skip anything larger rather than let one file dominate the budget. Above
  /// the 10MB upload ceiling enforced by storage-presign, so in practice this
  /// only guards against legacy oversized objects.
  static const int maxEntryBytes = 16 * 1024 * 1024;

  /// How long a `.tmp` file may exist before prune treats it as abandoned.
  /// Comfortably longer than any single write, short enough that a crashed one
  /// does not linger.
  static const Duration _tmpGracePeriod = Duration(minutes: 10);

  Directory? _dir;
  Future<Directory?>? _initializing;
  bool _disabled = false;

  /// Resolve (and create) the cache directory once, sharing the work if
  /// several downloads race on startup.
  Future<Directory?> _directory() {
    if (_disabled) return Future<Directory?>.value();
    // Re-check existence rather than trusting the memoised handle: the
    // directory can vanish under a running app (the user clears app data, a
    // disk cleanup tool runs, the profile is roamed). Without this every cache
    // operation would fail for the rest of the session.
    final dir = _dir;
    if (dir != null && dir.existsSync()) return Future<Directory?>.value(dir);
    _dir = null;
    return _initializing ??= _createDirectory();
  }

  Future<Directory?> _createDirectory() async {
    try {
      // Application *support*, not temp: the OS may clear temp mid-session,
      // and re-downloading everything is exactly what this class exists to
      // avoid. On Windows this lands under AppData\Roaming.
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}media_cache');
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      _dir = dir;
      return dir;
    } on Exception catch (e) {
      // A cache is an optimisation. If the directory cannot be created (a
      // locked-down profile, a full disk), fall back to network-only rather
      // than failing every image in the app.
      debugPrint('[MediaDiskCache] Disabled - cannot create cache dir: $e');
      _disabled = true;
      return null;
    } finally {
      _initializing = null;
    }
  }

  /// Filename for a storage path.
  ///
  /// Hashed rather than sanitised: storage_path arrives from the database, so
  /// using it to build a filename would let a crafted value containing parent
  /// directory segments write outside the cache directory. A SHA-256 hex
  /// digest is fixed-length, safe on every filesystem, and collision-free in
  /// practice.
  String _fileName(String storagePath) =>
      '${sha256.convert(utf8.encode(storagePath))}.bin';

  Future<File?> _fileFor(String storagePath) async {
    final dir = await _directory();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}${_fileName(storagePath)}');
  }

  /// Raw (still-encrypted) bytes for [storagePath], or null on a miss.
  Future<Uint8List?> get(String storagePath) async {
    try {
      final file = await _fileFor(storagePath);
      if (file == null || !file.existsSync()) return null;

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        // A zero-length file means a write was interrupted. Treat it as a miss
        // and clear it so the next download can replace it.
        await _quietDelete(file);
        return null;
      }

      // Touch so LRU eviction sees this as recently used. Best-effort: a
      // failure here only makes eviction less accurate.
      try {
        file.setLastModifiedSync(DateTime.now());
      } on Exception catch (_) {
        // Ignored deliberately.
      }

      return bytes;
    } on Exception catch (e) {
      debugPrint('[MediaDiskCache] Read failed for $storagePath: $e');
      return null;
    }
  }

  /// Store the raw bytes exactly as downloaded.
  Future<void> put(String storagePath, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxEntryBytes) return;

    try {
      final file = await _fileFor(storagePath);
      if (file == null) return;

      // Write to a temporary name and rename into place, so a crash or a
      // concurrent reader never observes a half-written file.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);

      await _evictToFit();
    } on Exception catch (e) {
      debugPrint('[MediaDiskCache] Write failed for $storagePath: $e');
    }
  }

  /// Drop every cached object whose storage path is not in [liveStoragePaths].
  ///
  /// Call this after a SUCCESSFUL history fetch only. Pruning against a failed
  /// or partial fetch would delete the whole cache over a dropped connection
  /// and then re-download it all.
  Future<void> prune(Set<String> liveStoragePaths) async {
    try {
      final dir = await _directory();
      if (dir == null || !dir.existsSync()) return;

      final keep = liveStoragePaths.map(_fileName).toSet();
      var removed = 0;

      final staleBefore = clock.now().subtract(_tmpGracePeriod);

      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;

        if (name.endsWith('.tmp')) {
          // In-progress writes belong to a live download and must be left
          // alone - but a .tmp abandoned by a crash was skipped here AND by
          // _evictToFit, so it survived forever. Anything older than the grace
          // period cannot still be being written.
          try {
            if (entity.lastModifiedSync().isBefore(staleBefore)) {
              await _quietDelete(entity);
              removed++;
            }
          } on FileSystemException {
            // Vanished under us, or unreadable; nothing to do.
          }
          continue;
        }

        if (keep.contains(name)) continue;
        await _quietDelete(entity);
        removed++;
      }

      if (removed > 0) {
        debugPrint('[MediaDiskCache] Pruned $removed expired object(s)');
      }
    } on Exception catch (e) {
      debugPrint('[MediaDiskCache] Prune failed: $e');
    }
  }

  /// Remove one object, e.g. when its clip is deleted.
  Future<void> remove(String storagePath) async {
    final file = await _fileFor(storagePath);
    if (file != null) await _quietDelete(file);
  }

  /// Wipe everything. Used on sign-out: the cache holds another account's
  /// media, and on an unencrypted account that media is plaintext.
  Future<void> clear() async {
    try {
      final dir = await _directory();
      if (dir == null || !dir.existsSync()) return;
      await for (final entity in dir.list()) {
        if (entity is File) await _quietDelete(entity);
      }
      debugPrint('[MediaDiskCache] Cleared');
    } on Exception catch (e) {
      debugPrint('[MediaDiskCache] Clear failed: $e');
    }
  }

  /// Total bytes currently on disk, for diagnostics and tests.
  Future<int> currentBytes() async {
    final dir = await _directory();
    if (dir == null || !dir.existsSync()) return 0;
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File) total += entity.lengthSync();
    }
    return total;
  }

  /// Delete least-recently-used entries until the cache fits in [maxBytes].
  Future<void> _evictToFit() async {
    final dir = await _directory();
    if (dir == null || !dir.existsSync()) return;

    final files = <File>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.tmp')) continue;
      files.add(entity);
      total += entity.lengthSync();
    }

    if (total <= maxBytes) return;

    final stats = <File, DateTime>{};
    for (final f in files) {
      try {
        stats[f] = f.lastModifiedSync();
      } on Exception catch (_) {
        // Unreadable stat: treat as ancient so it is evicted first.
        stats[f] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    files.sort((a, b) => stats[a]!.compareTo(stats[b]!));

    for (final f in files) {
      if (total <= maxBytes) break;
      final size = f.lengthSync();
      if (await _quietDelete(f)) total -= size;
    }
    debugPrint('[MediaDiskCache] Evicted down to $total bytes');
  }

  Future<bool> _quietDelete(File file) async {
    try {
      await file.delete();
      return true;
    } on Exception catch (_) {
      // Another process may hold it open on Windows; it will be caught by the
      // next prune.
      return false;
    }
  }
}
