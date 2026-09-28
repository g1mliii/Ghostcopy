import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

// Strings (including the large clip bodies) are immutable. Copy containers
// before queuing so a realtime list or nested metadata can be reused safely.
Object? _snapshotHistoryValue(Object? value) => switch (value) {
  Map<String, Object?>() => value.map(
    (key, value) => MapEntry(key, _snapshotHistoryValue(value)),
  ),
  List<Object?>() => value.map(_snapshotHistoryValue).toList(),
  _ => value,
};

String _encodeHistory(Map<String, Object?> snapshot) => jsonEncode(snapshot);

/// The last page of clipboard history, kept on disk so the app can show it
/// without a connection.
///
/// ## Why
///
/// History used to come from the network and nowhere else. A signed-in phone
/// opened with no signal - an elevator, a plane - restored its session from
/// disk, got as far as the main screen, and then showed "Failed to load
/// history" over clips it had displayed a minute earlier. Text clips are the
/// whole row, so there was nothing to fetch; they simply had not been kept.
///
/// ## Stored as the server sent it
///
/// Rows are written exactly as PostgREST returned them, before decryption. An
/// encrypted clip's `content` is its ciphertext, so an encrypted account keeps
/// nothing readable here, and the repository decrypts on load with the key the
/// Keychain already holds - which needs no network either. An account without
/// encryption keeps plaintext, which is what the server holds for it too.
///
/// Like ThumbnailDiskCache it lives in the OS cache directory rather than
/// application support, so it is not swept into a device backup, and the OS
/// may purge it under storage pressure - at worst that is the old behaviour.
/// It must be cleared on sign-out, and the owning user id is stored alongside
/// the rows and checked on every read, so a file that somehow survived an
/// account switch is ignored rather than shown.
class HistoryDiskCache {
  HistoryDiskCache._();

  static final HistoryDiskCache instance = HistoryDiskCache._();

  static const String _fileName = 'history_cache.json';

  /// Bumped if the stored shape changes; an unknown version reads as empty.
  static const int _version = 1;

  Directory? _dir;
  Future<Directory?>? _initializing;
  bool _disabled = false;

  /// Writes, removals and clears run one at a time, in the order asked for.
  ///
  /// Otherwise a save that began just before a sign-out could land after the
  /// clear meant to follow it, leaving the previous account's clips on disk.
  Future<void> _tail = Future<void>.value();

  Future<void> _serial(Future<void> Function() op) {
    final next = _tail.then((_) => op());
    // A failed op must not wedge every one queued behind it.
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<Directory?> _directory() {
    if (_disabled) return Future<Directory?>.value();
    final dir = _dir;
    if (dir != null && dir.existsSync()) return Future<Directory?>.value(dir);
    _dir = null;
    return _initializing ??= _createDirectory();
  }

  Future<Directory?> _createDirectory() async {
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}history');
      if (!dir.existsSync()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } on Exception catch (e) {
      // Offline history is a convenience: without it the app behaves as it
      // always did, so a failure here disables it rather than surfacing.
      debugPrint('[HistoryCache] Disabled - cannot create dir: $e');
      _disabled = true;
      return null;
    } finally {
      _initializing = null;
    }
  }

  File _file(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$_fileName');

  /// Replace the stored history for [userId] with [rows].
  Future<void> save(String userId, List<Map<String, dynamic>> rows) {
    final snapshot = <String, Object?>{
      'v': _version,
      'user': userId,
      'rows': _snapshotHistoryValue(rows),
    };
    final large =
        rows.length > 20 ||
        rows.fold<int>(
              0,
              (size, row) => size + ((row['content'] as String?)?.length ?? 0),
            ) >
            10240;
    // Reserve the queue position before yielding to the isolate. Otherwise
    // a sign-out clear could finish before encoding, then be undone by save.
    return _serial(() async {
      final String encoded;
      try {
        encoded = large
            ? await compute(_encodeHistory, snapshot)
            : _encodeHistory(snapshot);
      } on Object catch (e) {
        debugPrint('[HistoryCache] Not saved - rows not encodable: $e');
        return;
      }
      final dir = await _directory();
      if (dir == null) return;
      final target = _file(dir);
      // Written aside and renamed over, so a process killed mid-write leaves
      // the previous copy rather than a truncated one.
      final temp = File('${target.path}.tmp');
      try {
        await temp.writeAsString(encoded, flush: true);
        await temp.rename(target.path);
      } on Exception catch (e) {
        debugPrint('[HistoryCache] Save failed: $e');
        if (temp.existsSync()) await _quietDelete(temp);
      }
    });
  }

  /// The rows last saved for [userId], or an empty list when there are none,
  /// they belong to someone else, or the file cannot be read.
  Future<List<Map<String, dynamic>>> load(String userId) async {
    // Behind any write already queued, so a load never sees a half-applied
    // save or a clear that has been asked for but not yet run.
    await _tail;
    try {
      final dir = await _directory();
      if (dir == null) return const [];
      final file = _file(dir);
      if (!file.existsSync()) return const [];

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic> ||
          decoded['v'] != _version ||
          decoded['user'] != userId) {
        return const [];
      }
      final rows = decoded['rows'];
      if (rows is! List) return const [];
      return rows.whereType<Map<String, dynamic>>().toList();
    } on Object catch (e) {
      // FormatException from a corrupt file included: treat it as no cache.
      debugPrint('[HistoryCache] Load failed: $e');
      return const [];
    }
  }

  /// Drop one clip from the stored history, so a deleted clip does not come
  /// back the next time the app opens offline.
  Future<void> remove(String id) {
    return _serial(() async {
      final dir = await _directory();
      if (dir == null) return;
      final file = _file(dir);
      if (!file.existsSync()) return;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) return;
        final rows = decoded['rows'];
        if (rows is! List) return;
        final kept = rows
            .where((r) => r is! Map || r['id']?.toString() != id)
            .toList();
        if (kept.length == rows.length) return;
        decoded['rows'] = kept;
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(jsonEncode(decoded), flush: true);
        await temp.rename(file.path);
      } on Object catch (e) {
        // Unreadable means nothing to trust in it; remove the lot.
        debugPrint('[HistoryCache] Remove failed, clearing: $e');
        await _quietDelete(file);
      }
    });
  }

  /// Delete the stored history. Called on sign-out and account switch.
  Future<void> clear() {
    return _serial(() async {
      final dir = await _directory();
      if (dir == null) return;
      await _quietDelete(_file(dir));
      await _quietDelete(File('${_file(dir).path}.tmp'));
    });
  }

  Future<void> _quietDelete(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on Exception catch (e) {
      debugPrint('[HistoryCache] Delete failed: $e');
    }
  }
}
