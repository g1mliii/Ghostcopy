import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;

import '../../utils/xdg.dart';
import '../link_handler_service.dart';
import 'link_handler_service.dart';

/// Plain data returned from the Linux lookup isolate.
typedef LinuxLinkHandlerData = ({String name, Uint8List? png});

/// GIO is the association backend used by url_launcher's GTK/GIO launcher.
/// Lookup and file access run in an isolate; no helper process is spawned.
class LinuxLinkHandlerService extends CachingLinkHandlerService {
  LinuxLinkHandlerService({
    Future<LinuxLinkHandlerData?> Function(String scheme)? lookup,
  }) : _lookup = lookup ?? _lookupInIsolate,
       super(platform: 'linux');

  final Future<LinuxLinkHandlerData?> Function(String scheme) _lookup;

  @override
  String cacheKeyFor(Uri uri) => uri.scheme;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    final found = await _lookup(uri.scheme);
    if (found == null) return null;
    return LinkHandler(
      name: found.name,
      // Fresh bytes let the shared cache detect an icon replaced in place.
      icon: found.png == null ? null : MemoryImage(found.png!),
    );
  }
}

Future<LinuxLinkHandlerData?> _lookupInIsolate(String scheme) =>
    compute(_lookupLinuxHandler, scheme);

LinuxLinkHandlerData? _lookupLinuxHandler(String scheme) => using((arena) {
  final app = _defaultForScheme(scheme.toNativeUtf8(allocator: arena));
  if (app == nullptr) return null;
  try {
    final displayName = _displayName(app);
    if (displayName == nullptr) return null;
    final name = displayName.toDartString();
    if (name.isEmpty) return null;
    final icon = _appIcon(app);
    final names = <String>[];
    String? iconPath;
    if (icon != nullptr) {
      if (_isA(icon, _themedIconType()) != 0) {
        final nativeNames = _themedIconNames(icon);
        if (nativeNames != nullptr) {
          for (var i = 0; i < 128 && nativeNames[i] != nullptr; i++) {
            names.add(nativeNames[i].toDartString());
          }
        }
      } else if (_isA(icon, _fileIconType()) != 0) {
        final file = _iconFile(icon);
        final nativePath = file == nullptr ? nullptr : _filePath(file);
        if (nativePath != nullptr) {
          try {
            iconPath = nativePath.toDartString();
          } finally {
            _free(nativePath.cast());
          }
        }
      }
    }
    return (
      name: name,
      png: _readLinuxIcon((
        names: names,
        iconPath: iconPath,
        environment: Platform.environment,
      )),
    );
  } finally {
    // The icon and its names are borrowed from app; only app is owned here.
    _unref(app);
  }
});

typedef _IconRequest = ({
  List<String> names,
  String? iconPath,
  Map<String, String> environment,
});

/// Loads a Linux icon on a background isolate, including files replaced at
/// the same path. [names] are GIO's themed fallbacks, [iconPath] its local
/// file icon, and [environment] supplies the XDG data directories.
@visibleForTesting
Future<Uint8List?> readLinuxLinkIcon({
  required Map<String, String> environment,
  List<String> names = const [],
  String? iconPath,
}) => compute(_readLinuxIcon, (
  names: names,
  iconPath: iconPath,
  environment: environment,
));

Uint8List? _readLinuxIcon(_IconRequest request) {
  final candidates = <String>[];
  if (request.iconPath case final file? when path.isAbsolute(file)) {
    candidates.add(file);
  }
  final dataDirs = xdgDataDirs(request.environment);
  final home = request.environment['HOME'];
  final iconDirs = [
    if (home != null && path.isAbsolute(home)) path.join(home, '.icons'),
    for (final dir in dataDirs) path.join(dir, 'icons'),
  ];
  for (final name in request.names) {
    // A themed name is not a path. Local file icons use iconPath instead.
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) continue;
    final filename = name.endsWith('.png') ? name : '$name.png';
    for (final dir in iconDirs) {
      for (final size in ['64x64', '96x96', '128x128', '48x48', '256x256']) {
        candidates.add(path.join(dir, 'hicolor', size, 'apps', filename));
      }
    }
    for (final dir in dataDirs) {
      candidates.add(path.join(dir, 'pixmaps', filename));
    }
  }
  for (final candidate in candidates) {
    if (!candidate.endsWith('.png')) continue;
    try {
      final file = File(candidate).openSync();
      try {
        // Icons are thumbnails. Keep an accidentally huge file out of caches.
        const maxBytes = 1024 * 1024;
        final bytes = file.readSync(maxBytes + 1);
        if (bytes.isNotEmpty && bytes.length <= maxBytes) return bytes;
      } finally {
        file.closeSync();
      }
    } on FileSystemException {
      // Missing/unreadable files do not discard the app name or fallbacks.
      continue;
    }
  }
  return null;
}

// GTK already depends on these libraries. They are loaded lazily and only
// from the Linux worker, so importing this file on another OS is harmless.
final _gio = DynamicLibrary.open('libgio-2.0.so.0');
final _gobject = DynamicLibrary.open('libgobject-2.0.so.0');
final _glib = DynamicLibrary.open('libglib-2.0.so.0');

final _defaultForScheme = _gio
    .lookupFunction<
      Pointer<Void> Function(Pointer<Utf8>),
      Pointer<Void> Function(Pointer<Utf8>)
    >('g_app_info_get_default_for_uri_scheme');
final _displayName = _gio
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Void>),
      Pointer<Utf8> Function(Pointer<Void>)
    >('g_app_info_get_display_name');
final _appIcon = _gio
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('g_app_info_get_icon');
final _themedIconType = _gio.lookupFunction<UintPtr Function(), int Function()>(
  'g_themed_icon_get_type',
);
final _fileIconType = _gio.lookupFunction<UintPtr Function(), int Function()>(
  'g_file_icon_get_type',
);
final _isA = _gobject
    .lookupFunction<
      Int32 Function(Pointer<Void>, UintPtr),
      int Function(Pointer<Void>, int)
    >('g_type_check_instance_is_a');
final _themedIconNames = _gio
    .lookupFunction<
      Pointer<Pointer<Utf8>> Function(Pointer<Void>),
      Pointer<Pointer<Utf8>> Function(Pointer<Void>)
    >('g_themed_icon_get_names');
final _iconFile = _gio
    .lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)
    >('g_file_icon_get_file');
final _filePath = _gio
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Void>),
      Pointer<Utf8> Function(Pointer<Void>)
    >('g_file_get_path');
final _unref = _gobject
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'g_object_unref',
    );
final _free = _glib
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'g_free',
    );
