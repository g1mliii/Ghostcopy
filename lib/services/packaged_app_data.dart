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
/// Windows build, and a full-trust package's writes there were measured going
/// to the real folder rather than into the package (see tasks/todo.md). So an
/// uninstalled GhostCopy left its session, settings, encryption passphrase,
/// command-line secret and media cache on the machine.
///
/// [prepare] points path_provider at the package's folders instead, and moves
/// over what an earlier version left in AppData so nobody is signed out. An
/// unpackaged build is untouched: it has no package to be removed with, and
/// keeps using AppData as before.
class PackagedAppData {
  @visibleForTesting
  const PackagedAppData({required this.localState, required this.localCache});

  /// `ApplicationData.LocalFolder`: settings, the session, secrets.
  final String localState;

  /// `ApplicationData.LocalCacheFolder`: caches and the crash database.
  final String localCache;

  static PackagedAppData? _current;
  static bool _detected = false;

  /// This process's package folders, or null when it is not running from a
  /// package - which includes every platform but Windows.
  static PackagedAppData? get current {
    if (!_detected) {
      _detected = true;
      if (Platform.isWindows) {
        _current = forFamilyName(
          _currentPackageFamilyName(),
          localAppData: Platform.environment['LOCALAPPDATA'],
        );
      }
    }
    return _current;
  }

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

  /// Where an unpackaged GhostCopy - or this one, before it moved - keeps
  /// its data, each with where it goes now: path_provider's `<known
  /// folder>\<CompanyName>\<ProductName>`, from Runner.rc. Support data was
  /// under Roaming AppData, caches under Local. Spelled out rather than asked
  /// of path_provider, which creates the folder it is asked for.
  List<(String, String)> _legacyRoots(Map<String, String> env) => [
    for (final (known, target) in [
      (env['APPDATA'], localState),
      (env['LOCALAPPDATA'], localCache),
    ])
      if (known != null && known.isNotEmpty)
        (p.join(known, 'com.ghostcopy', 'ghostcopy'), target),
  ];

  /// The crash database's old home; see crash_reporting_service.dart.
  static String? _legacyCrashDatabase(Map<String, String> env) {
    final local = env['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    return p.join(local, 'GhostCopy', 'sentry-native');
  }

  /// Written once everything from AppData is in the package. Until then the
  /// app runs from AppData, as it always did, and the move is tried again.
  static const String _movedMarker = '.moved_from_appdata';

  /// Held while moving, so two GhostCopy processes starting together - the
  /// startup task and a click, or a sign-in callback - cannot both move the
  /// same files. This runs before SingleInstance has picked one of them.
  static const String _lockFile = '.moving.lock';

  static PackagedAppData? _inUse;

  /// The package's folders once the app runs from them, which is once
  /// [prepare] has everything across. Null before that, and outside a
  /// package.
  static PackagedAppData? get inUse => _inUse;

  /// Move over what an earlier version left in AppData, and then point
  /// path_provider at the package's folders. Call before anything opens a
  /// file; does nothing outside a package.
  static Future<void> prepare() async {
    final data = current;
    if (data == null) return;
    var moved = false;
    try {
      moved = await data.moveFromAppData(Platform.environment);
    } on Object catch (e) {
      // Never worth failing startup over: the app runs from AppData this
      // time, as it always did, and the next launch tries again.
      debugPrint('[PackagedAppData] Could not move data from AppData: $e');
    }
    // Only once everything is across. Running from the package with part of
    // the data still in AppData would have the app start afresh there - a new
    // session, a new passphrase - and the next attempt would then find that
    // in the way of the real one.
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
  /// - support data into [localState], caches and the crash database into
  /// [localCache] - and remove the emptied folders. Whether the package now
  /// holds all of it.
  ///
  /// All or nothing. Nothing in AppData is deleted until every item is in
  /// the package; if any one cannot be moved - held open, say, or a file
  /// where a folder of the same name already is - what was moved this time
  /// is moved back, and AppData is as it was. A file already in the package
  /// from an earlier attempt is whole, because copies land under a temporary
  /// name first, so its AppData copy goes; a folder already there is merged
  /// into, never taken as whole.
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

      final sources = [
        for (final (root, target) in _legacyRoots(env)) (root, target),
        if (_legacyCrashDatabase(env) case final crashes?)
          (crashes, p.join(localCache, 'sentry-native')),
      ];
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
        await _removeIfEmpty(Directory(source).parent); // com.ghostcopy
      }
      await marker.writeAsString('');
      return true;
    } finally {
      await lock.close();
    }
  }
}

/// One attempt at the move: what it has done, so it can be undone.
class _Move {
  /// Moved this time, as (from, to), to put back if the whole move fails.
  final List<(String, String)> _moved = [];

  /// Already in the package from an earlier attempt. Their AppData copies
  /// are removed only once everything else is across.
  final List<FileSystemEntity> _duplicates = [];

  /// Move [entity] to [target]. Whether all of it is now there.
  Future<bool> entity(FileSystemEntity entity, String target) async {
    if (!entity.existsSync()) return true;
    try {
      final existing = FileSystemEntity.typeSync(target);
      if (existing == FileSystemEntityType.notFound) {
        await _relocate(entity, target);
        _moved.add((entity.path, target));
        return true;
      }
      if (entity is Directory && existing == FileSystemEntityType.directory) {
        var complete = true;
        for (final child in entity.listSync()) {
          complete &= await this.entity(
            child,
            p.join(target, p.basename(child.path)),
          );
        }
        return complete;
      }
      if (entity is File && existing == FileSystemEntityType.file) {
        _duplicates.add(entity);
        return true;
      }
      // A file where a folder is, or the other way round: neither can stand
      // in for the other, so both are left as they are.
      debugPrint('[PackagedAppData] ${entity.path} does not fit $target');
      return false;
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
          FileSystemEntity.isDirectorySync(to) ? Directory(to) : File(to),
          from,
        );
      } on FileSystemException catch (e) {
        debugPrint('[PackagedAppData] Could not put back $to: ${e.message}');
      }
    }
    _moved.clear();
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
