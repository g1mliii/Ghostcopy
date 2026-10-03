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
    var moved = false;
    try {
      moved = await data.moveFromAppData(Platform.environment);
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
  /// one. So nothing in AppData is deleted until every item is across; a file
  /// where the package has a folder of the same name, or the other way
  /// round, is found before anything moves; and if one item cannot move -
  /// held open, say - what moved this time is put back. A file already in the
  /// package from an earlier attempt is whole, because copies land under a
  /// temporary name first, so its AppData copy goes; a folder already there is
  /// merged into, never taken as whole.
  @visibleForTesting
  Future<bool> moveFromAppData(Map<String, String> env) async {
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
      // Read-only first: a conflict like that never resolves itself, and
      // finding it by moving would move and put back everything on every
      // launch.
      for (final (source, target) in sources) {
        if (!_fits(Directory(source), target)) return false;
      }

      final move = _Move();
      var complete = true;
      for (final (source, target) in sources) {
        complete &= await move.entity(Directory(source), target);
      }
      if (!complete) {
        await move.undo();
        return false;
      }

      await move.removeDuplicates();
      for (final (source, _) in sources) {
        await _pruneEmpty(Directory(source));
        await _removeIfEmpty(Directory(source).parent); // the company folder
      }
      await marker.writeAsString('');
      return true;
    } finally {
      await lock.close();
    }
  }
}

/// Whether [entity] can move to [target]: nothing there, the same kind of
/// thing, or a folder whose contents fit in turn.
bool _fits(FileSystemEntity entity, String target) {
  if (!entity.existsSync()) return true;
  final existing = FileSystemEntity.typeSync(target);
  if (existing == FileSystemEntityType.notFound) return true;
  if (entity is File) return existing == FileSystemEntityType.file;
  if (existing != FileSystemEntityType.directory) return false;
  return (entity as Directory).listSync().every(
    (child) => _fits(child, p.join(target, p.basename(child.path))),
  );
}

/// One attempt at the move: what it has done, so it can be undone.
class _Move {
  /// Moved this time, to put back if the whole move fails.
  final List<(FileSystemEntity from, String to)> _moved = [];

  /// Already in the package from an earlier attempt. Their AppData copies
  /// are removed only once everything else is across.
  final List<FileSystemEntity> _duplicates = [];

  /// Move [entity] to [target], which [_fits] has cleared. Whether all of it
  /// is now there.
  Future<bool> entity(FileSystemEntity entity, String target) async {
    if (!entity.existsSync()) return true;
    try {
      final existing = FileSystemEntity.typeSync(target);
      if (existing == FileSystemEntityType.notFound) {
        await _relocate(entity, target);
        _moved.add((entity, target));
        return true;
      }
      if (entity is Directory) {
        var complete = true;
        for (final child in entity.listSync()) {
          complete &= await this.entity(
            child,
            p.join(target, p.basename(child.path)),
          );
        }
        return complete;
      }
      _duplicates.add(entity);
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
        await _relocate(
          from is Directory ? Directory(to) : File(to),
          from.path,
        );
      } on FileSystemException catch (e) {
        debugPrint('[PackagedAppData] Could not put back $to: ${e.message}');
      }
    }
  }

  Future<void> removeDuplicates() async {
    for (final duplicate in _duplicates) {
      try {
        await duplicate.delete();
      } on FileSystemException catch (e) {
        debugPrint('[PackagedAppData] Left ${duplicate.path}: ${e.message}');
      }
    }
  }
}

/// Rename [entity] to [target], or copy it there and delete it where a
/// rename cannot cross volumes. A copy interrupted part way leaves the
/// original whole.
Future<void> _relocate(FileSystemEntity entity, String target) async {
  await Directory(p.dirname(target)).create(recursive: true);
  try {
    await entity.rename(target);
  } on FileSystemException {
    await _copy(entity, target);
    await entity.delete(recursive: true);
  }
}

Future<void> _copy(FileSystemEntity entity, String target) async {
  if (entity is File) {
    // Whole or not at all: a half-written file under its real name would be
    // taken for the complete one on the next attempt.
    final partial = '$target.partial';
    await entity.copy(partial);
    await File(partial).rename(target);
  } else if (entity is Directory) {
    await Directory(target).create(recursive: true);
    for (final child in entity.listSync()) {
      await _copy(child, p.join(target, p.basename(child.path)));
    }
  }
}

/// Remove [dir] if nothing but empty folders is left in it.
Future<void> _pruneEmpty(Directory dir) async {
  if (!dir.existsSync()) return;
  for (final child in dir.listSync().whereType<Directory>()) {
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

/// path_provider for a packaged GhostCopy: support and cache under the
/// package's own folders, everything else - temporary files, Documents,
/// Downloads - where Windows keeps it for every app.
@visibleForTesting
class PackagedPathProvider extends PathProviderWindows {
  PackagedPathProvider(this._data);

  final PackagedAppData _data;

  @override
  Future<String?> getApplicationSupportPath() => _ensure(_data.localState);

  @override
  Future<String?> getApplicationCachePath() => _ensure(_data.localCache);

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
