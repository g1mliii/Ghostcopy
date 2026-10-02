import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';

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

  /// Written once everything from AppData has moved, so the move is tried
  /// again on the next launch until it has.
  static const String _movedMarker = '.moved_from_appdata';

  /// Point path_provider at the package's folders, and move over what an
  /// earlier version left in AppData. Call before anything opens a file;
  /// does nothing outside a package.
  static Future<void> prepare() async {
    final data = current;
    if (data == null) return;
    PathProviderPlatform.instance = PackagedPathProvider(data);
    try {
      await data.moveFromAppData(Platform.environment);
    } on Object catch (e) {
      // Never worth failing startup over: the app works from the package
      // either way, and the next launch tries again.
      debugPrint('[PackagedAppData] Could not move data from AppData: $e');
    }
  }

  /// Move everything an earlier version kept under AppData into the
  /// package - support data into [localState], caches and the crash database
  /// into [localCache] - then remove the emptied folders. Whatever the
  /// package already has wins over an AppData copy: it is what the app has
  /// been using.
  @visibleForTesting
  Future<void> moveFromAppData(Map<String, String> env) async {
    final marker = File(p.join(localState, _movedMarker));
    if (marker.existsSync()) return;
    await Directory(localState).create(recursive: true);

    var complete = true;
    for (final (root, target) in _legacyRoots(env)) {
      complete &= await _moveChildren(Directory(root), Directory(target));
    }
    final crashes = _legacyCrashDatabase(env);
    if (crashes != null) {
      final from = Directory(crashes);
      if (from.existsSync()) {
        complete &= await _moveEntity(
          from,
          p.join(localCache, 'sentry-native'),
        );
        await _removeIfEmpty(from.parent);
      }
    }
    if (complete) await marker.writeAsString('');
  }

  /// Whether everything in [from] ended up in [to].
  static Future<bool> _moveChildren(Directory from, Directory to) async {
    if (!from.existsSync()) return true;
    var complete = true;
    for (final entity in from.listSync()) {
      complete &= await _moveEntity(
        entity,
        p.join(to.path, p.basename(entity.path)),
      );
    }
    if (complete) {
      await _removeIfEmpty(from);
      await _removeIfEmpty(from.parent); // com.ghostcopy
    }
    return complete;
  }

  /// Move [entity] to [target]; false if it could not be moved, in which
  /// case it is left where it was.
  static Future<bool> _moveEntity(
    FileSystemEntity entity,
    String target,
  ) async {
    try {
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        // Already in the package, and that copy is the one in use.
        await entity.delete(recursive: true);
        return true;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      try {
        await entity.rename(target);
      } on FileSystemException {
        // Rename cannot cross volumes; copy, then remove the original.
        await _copy(entity, target);
        await entity.delete(recursive: true);
      }
      return true;
    } on FileSystemException catch (e) {
      // Most likely held open by an unpackaged build running alongside.
      debugPrint('[PackagedAppData] Left ${entity.path}: ${e.message}');
      return false;
    }
  }

  static Future<void> _copy(FileSystemEntity entity, String target) async {
    if (entity is File) {
      await entity.copy(target);
    } else if (entity is Directory) {
      await Directory(target).create(recursive: true);
      for (final child in entity.listSync()) {
        await _copy(child, p.join(target, p.basename(child.path)));
      }
    }
  }

  static Future<void> _removeIfEmpty(Directory dir) async {
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) await dir.delete();
    } on FileSystemException {
      // Something else put a file there; leave it.
    }
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
