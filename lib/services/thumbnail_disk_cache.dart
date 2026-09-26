import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Small rendered previews of clipboard images, kept on disk between launches.
///
/// ## Why this exists separately from MediaDiskCache
///
/// MediaDiskCache holds the object exactly as stored - full size, and still
/// encrypted when the clip is. Producing a thumbnail from that costs a disk
/// read, an isolate spawn, an AES pass and a full-size decode, and it was
/// being paid on every cold launch for every image in history. The bytes were
/// local the whole time; it still felt like downloading.
///
/// A thumbnail is a few tens of KB and decodes in a moment, so caching the
/// *result* removes all four costs.
///
/// ## Deliberately never returned by downloadFile
///
/// Nothing here is reachable from `IClipboardRepository.downloadFile`, which
/// is what save, share, drag-out and copy-to-clipboard all use. A thumbnail
/// can therefore never be saved or shared in place of the real image - a bug
/// this project has had before. Keeping the two in separate stores with
/// separate call paths is what makes that structurally impossible rather than
/// a thing to remember.
///
/// ## Stored in the clear
///
/// Even for an encrypted clip. Decided deliberately: these are never uploaded,
/// and they live in the OS cache directory rather than application support,
/// so they are not swept into a device backup or a roaming Windows profile, and encrypting them would put back the
/// isolate spawn and AES pass this exists to remove. The consequence is that
/// a low-resolution copy of an encrypted clip does sit in the profile
/// directory, so [clear] must be called on sign-out exactly as MediaDiskCache
/// is, and [prune] keeps it in step with the history the user still has.
class ThumbnailDiskCache {
  ThumbnailDiskCache._();

  static final ThumbnailDiskCache instance = ThumbnailDiskCache._();

  /// The longest edge a cached thumbnail is rendered at, in physical pixels.
  ///
  /// One canonical size rather than one per call site: a cache keyed by
  /// requested size would hold near-duplicates of the same picture, and every
  /// list in the app draws these well under this. Anything larger than this
  /// asks for the full image instead, so a full-screen preview never gets an
  /// upscaled thumbnail.
  static const int maxEdge = 512;

  /// Thumbnails are small; this is thousands of them. The cap exists so a
  /// long-lived install cannot grow without bound, not because it is expected
  /// to be reached.
  static const int maxBytes = 32 * 1024 * 1024;

  Directory? _dir;
  Future<Directory?>? _initializing;
  bool _disabled = false;

  /// Writes and removals run one at a time, in the order they were asked for.
  ///
  /// Otherwise a thumbnail write that began just before a delete or a
  /// sign-out could land after the removal meant to follow it, leaving a
  /// plaintext preview of a clip - or an account - that is gone.
  Future<void> _tail = Future<void>.value();

  Future<void> _serial(Future<void> Function() op) {
    final next = _tail.then((_) => op());
    // A failed op must not wedge every one queued behind it.
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<Directory?> _directory() {
    if (_disabled) return Future<Directory?>.value();
    // Re-checked rather than trusted, for the same reason MediaDiskCache does:
    // the directory can vanish under a running app.
    final dir = _dir;
    if (dir != null && dir.existsSync()) return Future<Directory?>.value(dir);
    _dir = null;
    return _initializing ??= _createDirectory();
  }

  Future<Directory?> _createDirectory() async {
    try {
      // The cache directory, not application support: that one is included
      // in iOS and Android backups and roams with a Windows profile, and
      // these are plaintext previews that must stay on this device.
      final base = await getApplicationCacheDirectory();
      final dir = Directory(
        '${base.path}${Platform.pathSeparator}thumbnail_cache',
      );
      if (!dir.existsSync()) await dir.create(recursive: true);
      _dir = dir;
      unawaited(_removeLegacyDirectory());
      return dir;
    } on Exception catch (e) {
      // A cache is an optimisation: fall back to rendering from the full
      // image rather than failing to show anything.
      debugPrint('[ThumbnailCache] Disabled - cannot create dir: $e');
      _disabled = true;
      return null;
    } finally {
      _initializing = null;
    }
  }

  /// Where development builds of this cache kept it before it moved to the
  /// cache directory. Best effort: nothing depends on it being gone, it just
  /// should not linger.
  Future<void> _removeLegacyDirectory() async {
    try {
      final support = await getApplicationSupportDirectory();
      final legacy = Directory(
        '${support.path}${Platform.pathSeparator}thumbnail_cache',
      );
      if (legacy.path == _dir?.path) return;
      if (legacy.existsSync()) await legacy.delete(recursive: true);
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Could not remove old cache: $e');
    }
  }

  /// Hashed, because storage_path comes from the database and must never be
  /// interpolated into a filesystem path.
  String _fileName(String storagePath) =>
      '${sha256.convert(utf8.encode(storagePath))}.png';

  Future<File?> _fileFor(String storagePath) async {
    final dir = await _directory();
    if (dir == null) return null;
    return File(
      '${dir.path}${Platform.pathSeparator}${_fileName(storagePath)}',
    );
  }

  /// The cached thumbnail for [storagePath], or null on a miss.
  Future<Uint8List?> get(String storagePath) async {
    try {
      final file = await _fileFor(storagePath);
      if (file == null || !file.existsSync()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      // Touched so the LRU eviction below has something to order by.
      unawaited(_touch(file));
      return bytes;
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Read failed for $storagePath: $e');
      return null;
    }
  }

  Future<void> put(String storagePath, Uint8List png) =>
      _serial(() => _put(storagePath, png));

  Future<void> _put(String storagePath, Uint8List png) async {
    try {
      final file = await _fileFor(storagePath);
      if (file == null) return;
      // Written to a temp name and renamed, so a half-written file can never
      // be read back as a corrupt thumbnail.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(png, flush: true);
      await tmp.rename(file.path);
      unawaited(_evictToFit());
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Write failed for $storagePath: $e');
    }
  }

  Future<void> remove(String storagePath) =>
      _serial(() => _remove(storagePath));

  Future<void> _remove(String storagePath) async {
    try {
      final file = await _fileFor(storagePath);
      if (file != null && file.existsSync()) await file.delete();
    } on Exception catch (_) {
      // Nothing to do: a thumbnail that cannot be deleted is pruned later.
    }
  }

  /// Drop thumbnails for clips the user no longer has.
  ///
  /// Mirrors MediaDiskCache.prune and is called from the same place, so the
  /// two stores cannot drift apart into one holding previews of clips the
  /// other has already forgotten.
  Future<void> prune(Set<String> liveStoragePaths) =>
      _serial(() => _prune(liveStoragePaths));

  Future<void> _prune(Set<String> liveStoragePaths) async {
    try {
      final dir = await _directory();
      if (dir == null || !dir.existsSync()) return;
      final keep = liveStoragePaths.map(_fileName).toSet();
      var removed = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.endsWith('.tmp')) {
          await entity.delete();
          continue;
        }
        if (!keep.contains(name)) {
          await entity.delete();
          removed++;
        }
      }
      if (removed > 0) debugPrint('[ThumbnailCache] Pruned $removed');
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Prune failed: $e');
    }
  }

  /// Delete everything. Called on sign-out: these are plaintext previews of
  /// one account's clips and must not outlive its session on a shared machine.
  Future<void> clear() => _serial(_clear);

  Future<void> _clear() async {
    try {
      final dir = await _directory();
      if (dir == null || !dir.existsSync()) return;
      await for (final entity in dir.list()) {
        if (entity is File) await entity.delete();
      }
      debugPrint('[ThumbnailCache] Cleared');
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Clear failed: $e');
    }
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastAccessed(DateTime.now());
    } on Exception catch (_) {
      // Not every filesystem supports this; eviction falls back to mtime.
    }
  }

  Future<void> _evictToFit() async {
    try {
      final dir = await _directory();
      if (dir == null || !dir.existsSync()) return;
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        files.add(entity);
        total += await entity.length();
      }
      if (total <= maxBytes) return;
      files.sort(
        (a, b) => a.statSync().accessed.compareTo(b.statSync().accessed),
      );
      for (final file in files) {
        if (total <= maxBytes) break;
        total -= await file.length();
        await file.delete();
      }
    } on Exception catch (e) {
      debugPrint('[ThumbnailCache] Eviction failed: $e');
    }
  }
}
