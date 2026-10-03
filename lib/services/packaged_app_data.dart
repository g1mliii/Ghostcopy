import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// Where a Microsoft Store (MSIX) GhostCopy keeps its data, so that
/// uninstalling it leaves nothing behind.
///
/// Windows deletes a package's own folders - `%LOCALAPPDATA%\Packages\<family
/// name>\LocalState` and `LocalCache` - with the package. It does not delete
/// `%APPDATA%\com.ghostcopy`, which is where path_provider points every
/// Windows build. A full-trust package's writes there are redirected into the
/// package only for files that did not already exist (measured 2026-09-25 on
/// a machine that already had them: every write went to the real folder; see
/// tasks/todo.md), so how much an uninstall left behind depended on what
/// came first. Using the package's folders explicitly makes it the same on
/// every machine.
///
/// [prepare] moves over what an earlier version left in AppData, so nobody
/// is signed out, then points path_provider and shared_preferences at the
/// package's folders. An unpackaged build is untouched: it has no package to
/// be removed with, and keeps using AppData as before.
class PackagedAppData {
  @visibleForTesting
  const PackagedAppData({required this.localState, required this.localCache});

  /// `ApplicationData.LocalFolder`: settings, the session, secrets.
  final String localState;

  /// `ApplicationData.LocalCacheFolder`: caches and the crash database.
  final String localCache;

  /// The folders Windows keeps for the package [familyName] under
  /// [localAppData]. Null when either is missing.
  @visibleForTesting
  static PackagedAppData? forFamilyName(
    String? familyName, {
    required String? localAppData,
  }) {
    if (familyName == null || familyName.isEmpty) return null;
    if (localAppData == null || localAppData.isEmpty) return null;
    final root = p.join(localAppData, 'Packages', familyName);
    return PackagedAppData(
      localState: p.join(root, 'LocalState'),
      localCache: p.join(root, 'LocalCache'),
    );
  }

  /// Where an unpackaged build keeps sentry-native's crash database, under
  /// [root] - LOCALAPPDATA on Windows, the XDG cache on Linux. Shared with
  /// crash reporting, so the move below looks where the database really is.
  static String unpackagedCrashDatabase(String root) =>
      p.join(root, 'GhostCopy', 'sentry-native');

  /// What an unpackaged GhostCopy - or this one, before it moved - keeps
  /// under AppData, each with where it goes in the package: path_provider's
  /// `<known folder>\<CompanyName>\<ProductName>` from Runner.rc (support
  /// data under Roaming, caches under Local), and the crash database. Spelled
  /// out rather than asked of path_provider, which creates the folder it is
  /// asked for.
  List<(String, String)> _legacySources(Map<String, String> env) {
    String? known(String key) {
      final value = env[key];
      return value == null || value.isEmpty ? null : value;
    }

    final roaming = known('APPDATA');
    final local = known('LOCALAPPDATA');
    return [
      if (roaming != null)
        (p.join(roaming, 'com.ghostcopy', 'ghostcopy'), localState),
      if (local != null) ...[
        (p.join(local, 'com.ghostcopy', 'ghostcopy'), localCache),
        (unpackagedCrashDatabase(local), p.join(localCache, 'sentry-native')),
      ],
    ];
  }

  /// Written once everything from AppData is in the package.
  static const String _movedMarker = '.moved_from_appdata';

  /// Held while moving, so two GhostCopy processes starting together - the
  /// startup task and a click, or a sign-in callback - cannot both move the
  /// same files. This runs before SingleInstance has picked one of them.
  static const String _lockFile = '.moving.lock';

  /// File destinations recorded before any source moves, for crash recovery.
  static const String _moveJournal = '.moving_files.json';

  static PackagedAppData? _inUse;

  /// The package's folders, once the app runs from them. Null before
  /// [prepare] has moved everything across, and outside a package.
  static PackagedAppData? get inUse => _inUse;

  /// Move over what an earlier version left in AppData, then point
  /// path_provider and shared_preferences at the package's folders - only if
  /// that worked; see [moveFromAppData]. Call before anything opens a file;
  /// does nothing outside a package.
  static Future<void> prepare() async {
    if (!Platform.isWindows) return;
    final data = forFamilyName(
      _currentPackageFamilyName(),
      localAppData: Platform.environment['LOCALAPPDATA'],
    );
    if (data == null) return;
    await prepareForData(data, Platform.environment);
  }

  /// Run startup migration for [data] and [env]. [beforeCommit] lets tests
  /// reproduce another process writing or locking a file after it moved.
  @visibleForTesting
  static Future<void> prepareForData(
    PackagedAppData data,
    Map<String, String> env, {
    Future<void> Function()? beforeCommit,
  }) async {
    var moved = false;
    try {
      moved = await data.moveFromAppData(env, beforeCommit: beforeCommit);
    } on PackagedAppDataRecoveryException {
      // AppData is incomplete. Stop before authentication or settings can
      // create replacement data; a later launch retries durable recovery.
      rethrow;
    } on Object catch (e) {
      // Never worth failing startup over.
      debugPrint('[PackagedAppData] Could not move data from AppData: $e');
    }
    if (moved) {
      install(data);
      _inUse = data;
    }
  }

  /// Point everything that finds the app's folders at [data]'s.
  @visibleForTesting
  static void install(PackagedAppData data) {
    final provider = PackagedPathProvider(data);
    PathProviderPlatform.instance = provider;
    // shared_preferences' Windows backends do not go through
    // PathProviderPlatform: each builds a PathProviderWindows of its own, so
    // the line above alone leaves them reading AppData - an empty file once
    // the move has run, and the session and settings with it. Both take the
    // packaged provider through the field the package exposes for its own
    // tests, which is why the lint is silenced; it is a plain public field.
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
      // ignore: invalid_use_of_visible_for_testing_member
      ..pathProvider = provider;
    SharedPreferencesAsyncPlatform.instance = SharedPreferencesAsyncWindows()
      // ignore: invalid_use_of_visible_for_testing_member
      ..pathProvider = provider;
  }

  /// Move everything an earlier version kept under AppData into the package
  /// and remove the emptied folders. Whether the package now holds all of it.
  ///
  /// All or nothing, because the app runs from the package only once this
  /// says so - until then from AppData, as it always did, trying again on the
  /// next launch. Running from the package with part of the data still in
  /// AppData would have it start afresh there - a new session, a new
  /// passphrase - which the next attempt would then keep in place of the real
  /// one. Each file is tracked so it can be restored until the marker commits
  /// the move; a file where the package has a folder of the same name, or
  /// the other way round, is found before anything moves; and if one item
  /// cannot move - held open, say - what moved this time is put back. Anything already in
  /// the package is what an earlier attempt left - the app has not run from
  /// the package yet - while the AppData copy is the one the app went on
  /// using, so the AppData copy replaces it, and remnants deleted from the
  /// live source are removed before merging, file by file. An absent source
  /// root alone cannot prove deletion: an older migration may have renamed
  /// that whole root before failing to commit, leaving its only copy here.
  /// Reads legacy roots from [env]; [beforeCommit] reproduces concurrent
  /// writes and locks in tests, after the planned files have moved.
  @visibleForTesting
  Future<bool> moveFromAppData(
    Map<String, String> env, {
    Future<void> Function()? beforeCommit,
  }) async {
    final marker = File(p.join(localState, _movedMarker));
    if (marker.existsSync()) return true;
    await Directory(localState).create(recursive: true);

    final lock = await File(
      p.join(localState, _lockFile),
    ).open(mode: FileMode.write);
    try {
      await lock.lock(FileLock.blockingExclusive);
      // Another process may have finished while this one waited.
      if (marker.existsSync()) return true;

      final sources = _legacySources(env);
      final journal = File(p.join(localState, _moveJournal));
      await _restoreInterruptedMove(journal, sources);
      // Read-only first: a conflict like that never resolves itself, and
      // finding it by moving would move and put back everything on every
      // launch.
      for (final (source, target) in sources) {
        if (!_fits(Directory(source), target)) return false;
      }

      final move = _Move();
      try {
        // Reconcile before moving anything, while each live source tree is
        // still whole. Otherwise a completed child would look deleted.
        for (final (source, target) in sources) {
          await _removeRemnants(
            Directory(source),
            Directory(target),
            keep: p.equals(target, localState)
                ? {
                    _lockFile,
                    _movedMarker,
                    '$_movedMarker.partial',
                    _moveJournal,
                    '$_moveJournal.partial',
                  }
                : p.equals(target, localCache)
                ? {'sentry-native'} // migrated from its own legacy source
                : const {},
          );
        }
        final planned = [
          for (final (source, target) in sources)
            ..._planFiles(Directory(source), target),
        ];
        // With the plan durable first, a terminated process cannot make a
        // moved original look like a deletion during the next reconciliation.
        final partialJournal = File('${journal.path}.partial');
        await partialJournal.writeAsString(jsonEncode(planned), flush: true);
        await partialJournal.rename(journal.path);
        var complete = true;
        for (final entry in planned) {
          complete &= await move.entity(
            entry[2] == 'link' ? Link(entry[0]) : File(entry[0]),
            entry[1],
          );
        }
        if (!complete) {
          await move.undo();
          await _restoreInterruptedMove(journal, sources);
          return false;
        }

        await beforeCommit?.call();
        for (final (source, _) in sources) {
          await _pruneEmpty(Directory(source));
          await _removeIfEmpty(Directory(source).parent); // the company folder
        }
        // Commit only after a complete, flushed write. A failed write must
        // not leave a marker that makes the next attempt skip migration.
        final partial = File('${marker.path}.partial');
        await partial.writeAsString('', flush: true);
        for (final (source, _) in sources) {
          final directory = Directory(source);
          if (directory.existsSync() && directory.listSync().isNotEmpty) {
            throw FileSystemException(
              'Legacy data changed during migration',
              source,
            );
          }
        }
        await partial.rename(marker.path);
        try {
          await journal.delete();
        } on FileSystemException catch (e) {
          // The marker has committed: recovery is no longer needed, and a
          // cleanup failure must not send this launch back to AppData.
          debugPrint('[PackagedAppData] Left the recovery plan: ${e.message}');
        }
        return true;
      } on FileSystemException catch (e) {
        debugPrint('[PackagedAppData] Could not finish the move: ${e.message}');
        await move.undo();
        // This throws a recovery exception if any original remains missing;
        // prepare must not start the app against incomplete AppData.
        await _restoreInterruptedMove(journal, sources);
        return false;
      }
    } finally {
      try {
        await lock.close();
      } on FileSystemException catch (e) {
        // A committed move must still select the package's providers.
        debugPrint('[PackagedAppData] Could not close the lock: ${e.message}');
      }
    }
  }
}

/// Startup cannot safely use AppData until the pending migration is restored.
class PackagedAppDataRecoveryException implements Exception {
  const PackagedAppDataRecoveryException(this.message);

  final String message;

  @override
  String toString() => 'PackagedAppDataRecoveryException: $message';
}

/// Plan every individual file in [source] before moving it to [target].
Iterable<List<String>> _planFiles(
  FileSystemEntity source,
  String target,
) sync* {
  if (!source.existsSync()) return;
  if (source is File || source is Link) {
    yield [source.path, target, if (source is Link) 'link' else 'file'];
  } else if (source is Directory) {
    for (final child in source.listSync(followLinks: false)) {
      yield* _planFiles(child, p.join(target, p.basename(child.path)));
    }
  }
}

/// Restore files moved before a process interruption, preserving any live
/// source that still exists. Validate every path against [sources] first.
Future<void> _restoreInterruptedMove(
  File journal,
  List<(String, String)> sources,
) async {
  if (!journal.existsSync()) return;
  try {
    final decoded = jsonDecode(await journal.readAsString()) as Object?;
    if (decoded is! List<Object?>) {
      throw const FormatException('Invalid migration recovery plan');
    }
    final entries = <List<String>>[];
    for (final entry in decoded) {
      if (entry is! List<Object?> || entry.any((value) => value is! String)) {
        throw const FormatException('Invalid migration recovery entry');
      }
      entries.add(entry.cast<String>());
    }
    for (final entry in entries) {
      if ((entry.length != 2 && entry.length != 3) ||
          (entry.length == 3 && entry[2] != 'file' && entry[2] != 'link') ||
          !sources.any(
            (root) =>
                p.isWithin(root.$1, entry[0]) &&
                p.equals(
                  p.join(root.$2, p.relative(entry[0], from: root.$1)),
                  entry[1],
                ),
          )) {
        throw FileSystemException(
          'Invalid migration recovery path',
          journal.path,
        );
      }
    }
    for (final entry in entries.reversed) {
      if (!_exists(entry[0])) {
        await _relocate(
          entry.length == 3 && entry[2] == 'link'
              ? Link(entry[1])
              : File(entry[1]),
          entry[0],
        );
      }
    }
    await journal.delete();
  } on Exception catch (e) {
    throw PackagedAppDataRecoveryException('Recovery remains pending: $e');
  }
}

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// Remove destination-only children while [source] is still authoritative.
/// [keep] protects migration metadata and independently migrated root folders.
Future<void> _removeRemnants(
  Directory source,
  Directory target, {
  Set<String> keep = const {},
}) async {
  if (!source.existsSync() || !target.existsSync()) return;
  for (final child in target.listSync(followLinks: false)) {
    final name = p.basename(child.path);
    if (keep.contains(name)) continue;
    final original = p.join(source.path, name);
    final type = FileSystemEntity.typeSync(original, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      await child.delete(recursive: true);
    } else if (child is Directory && type == FileSystemEntityType.directory) {
      await _removeRemnants(Directory(original), child);
    }
  }
}

/// Whether [entity] can move to [target]: nothing there, the same kind of
/// thing, or a folder whose contents fit in turn.
bool _fits(FileSystemEntity entity, String target) {
  if (!entity.existsSync()) return true;
  final existing = FileSystemEntity.typeSync(target, followLinks: false);
  if (existing == FileSystemEntityType.notFound) return true;
  if (entity is Link) return existing == FileSystemEntityType.link;
  if (entity is File) return existing == FileSystemEntityType.file;
  if (existing != FileSystemEntityType.directory) return false;
  return (entity as Directory)
      .listSync(followLinks: false)
      .every((child) => _fits(child, p.join(target, p.basename(child.path))));
}

/// One attempt at the move: what it has done, so it can be undone.
class _Move {
  /// Moved this time, to put back if the whole move fails.
  final List<(FileSystemEntity from, String to)> _moved = [];

  /// Move [entity] to [target], which [_fits] has cleared. Whether all of it
  /// is now there.
  Future<bool> entity(FileSystemEntity entity, String target) async {
    if (!entity.existsSync()) return true;
    try {
      // The durable plan contains individual files and links. Moving only
      // that snapshot leaves late arrivals for the final source check.
      // A file an earlier attempt left; the AppData one is newer, or the
      // same. If the remnant cannot go, nothing is committed and the next
      // attempt tries again.
      if (_exists(target)) {
        await (entity is Link ? Link(target) : File(target)).delete();
      }
      await _relocate(entity, target);
      _moved.add((entity, target));
      return true;
    } on FileSystemException catch (e) {
      // Most likely held open - by an unpackaged build running alongside, or
      // by antivirus or backup software.
      debugPrint('[PackagedAppData] Left ${entity.path}: ${e.message}');
      return false;
    }
  }

  /// Put back everything moved this time, newest first.
  Future<void> undo() async {
    for (final (from, to) in _moved.reversed) {
      try {
        // A concurrent legacy process may have recreated a newer source.
        if (_exists(from.path)) continue;
        await _relocate(from is Link ? Link(to) : File(to), from.path);
      } on FileSystemException catch (e) {
        debugPrint('[PackagedAppData] Could not put back $to: ${e.message}');
      }
    }
  }
}

/// Rename [entity] to [target], or copy it there and delete it where a rename
/// cannot cross volumes. Either operation leaves the original whole on
/// failure: only individual files are deleted, never a directory tree.
Future<void> _relocate(FileSystemEntity entity, String target) async {
  await Directory(p.dirname(target)).create(recursive: true);
  if (entity is Link) {
    final originalTarget = await entity.target();
    if (!p.isAbsolute(originalTarget)) {
      // Relative link targets need to retain their original meaning after
      // moving to a different parent. Never follow or copy their contents.
      await Link(
        target,
      ).create(p.normalize(p.join(p.dirname(entity.path), originalTarget)));
      await entity.delete();
      return;
    }
    try {
      await entity.rename(target);
    } on FileSystemException {
      await Link(target).create(originalTarget);
      await entity.delete();
    }
    return;
  }
  if (entity is! File) {
    throw FileSystemException('Unsupported migration entity', entity.path);
  }
  final file = entity;
  try {
    await file.rename(target);
  } on FileSystemException {
    // Whole or not at all: a half-written file under its real name would be
    // taken for the complete one on the next attempt.
    final partial = '$target.partial';
    await file.copy(partial);
    await File(partial).rename(target);
    await file.delete();
  }
}

/// Remove [dir] if nothing but empty folders is left in it.
Future<void> _pruneEmpty(Directory dir) async {
  if (!dir.existsSync()) return;
  for (final child in dir.listSync(followLinks: false).whereType<Directory>()) {
    await _pruneEmpty(child);
  }
  await _removeIfEmpty(dir);
}

Future<void> _removeIfEmpty(Directory dir) async {
  try {
    if (dir.existsSync() && dir.listSync().isEmpty) await dir.delete();
  } on FileSystemException {
    // Something else put a file there; leave it.
  }
}

/// path_provider for a packaged GhostCopy: support, cache and temporary
/// files under the package's own folders; Documents and Downloads where
/// Windows keeps them for every app.
@visibleForTesting
class PackagedPathProvider extends PathProviderWindows {
  PackagedPathProvider(this._data);

  final PackagedAppData _data;

  @override
  Future<String?> getApplicationSupportPath() => _ensure(_data.localState);

  @override
  Future<String?> getApplicationCachePath() => _ensure(_data.localCache);

  @override
  Future<String?> getTemporaryPath() =>
      _ensure(p.join(_data.localCache, 'Temp'));

  static Future<String?> _ensure(String path) async {
    await Directory(path).create(recursive: true);
    return path;
  }
}

/// The calling process's package family name, or null when it has none.
String? _currentPackageFamilyName() {
  const errorInsufficientBuffer = 122;
  try {
    final getFamilyName = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Uint32>, Pointer<Utf16>),
          int Function(Pointer<Uint32>, Pointer<Utf16>)
        >('GetCurrentPackageFamilyName');
    final length = calloc<Uint32>();
    try {
      // Unpackaged, this answers APPMODEL_ERROR_NO_PACKAGE; packaged, that
      // the null buffer is too small, with the length it needs.
      if (getFamilyName(length, nullptr) != errorInsufficientBuffer) {
        return null;
      }
      final buffer = calloc<Uint16>(length.value).cast<Utf16>();
      try {
        return getFamilyName(length, buffer) == 0
            ? buffer.toDartString()
            : null;
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(length);
    }
  } on Object catch (e) {
    debugPrint('[PackagedAppData] Could not read the package name: $e');
    return null;
  }
}
