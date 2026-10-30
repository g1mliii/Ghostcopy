import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../models/clip_link.dart';
import '../../utils/xdg.dart';
import '../link_handler_service.dart';
import 'command_line_tool_service.dart' show ProcessRunner;

/// The caching every platform shares: one lookup per [linkHandlerCacheKey],
/// refreshed after [maxAge] so a default app changed while GhostCopy sits in
/// the tray for a week is picked up.
abstract class CachingLinkHandlerService implements ILinkHandlerService {
  CachingLinkHandlerService({required this.platform});

  /// The `device_type_enum` value [ClipLink.openUri] is asked for.
  final String platform;

  static const maxAge = Duration(minutes: 10);

  final _pending = <String, Future<LinkHandler?>>{};
  final _resolved = <String, LinkHandler?>{};
  final _askedAt = <String, DateTime>{};

  /// Which app opens [uri], or null if none, or none in particular.
  @protected
  Future<LinkHandler?> lookUp(Uri uri);

  @override
  Future<LinkHandler?> handlerFor(ClipLink link) {
    final key = linkHandlerCacheKey(link, platform);
    final askedAt = _askedAt[key];
    if (askedAt != null && DateTime.now().difference(askedAt) > maxAge) {
      unawaited(_pending.remove(key));
    }
    return _pending[key] ??= () {
      _askedAt[key] = DateTime.now();
      return _lookUpSafely(link.openUri(platform)).then((handler) {
        _resolved[key] = handler;
        return handler;
      });
    }();
  }

  @override
  LinkHandler? cachedHandlerFor(ClipLink link) =>
      _resolved[linkHandlerCacheKey(link, platform)];

  /// An icon is decoration: anything that goes wrong finding it leaves the
  /// generic glyph, never an error the user sees.
  ///
  /// Object, not Exception: the Windows lookup is FFI and image encoding, and
  /// what those throw (ArgumentError, RangeError) are Errors. One escaping
  /// would be cached in `_pending` and rethrown, unhandled, to every row.
  Future<LinkHandler?> _lookUpSafely(Uri uri) async {
    try {
      return await lookUp(uri);
    } on Object catch (e) {
      debugPrint('[LinkHandler] No handler for ${uri.scheme}: $e');
      return null;
    }
  }
}

/// iOS, and anywhere else with no way to ask.
class NoLinkHandlerService implements ILinkHandlerService {
  const NoLinkHandlerService();

  @override
  Future<LinkHandler?> handlerFor(ClipLink link) async => null;

  @override
  LinkHandler? cachedHandlerFor(ClipLink link) => null;
}

/// macOS (`NSWorkspace.urlForApplication(toOpen:)`, in MainFlutterWindow.swift)
/// and Android (`PackageManager.resolveActivity`, in LinkHandler.kt). Both
/// answer `{name, icon}` with the icon as PNG bytes, or null.
class ChannelLinkHandlerService extends CachingLinkHandlerService {
  ChannelLinkHandlerService({required super.platform, MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.ghostcopy/link_handler');

  final MethodChannel _channel;

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'handlerFor',
      {'url': uri.toString()},
    );
    final name = result?['name'];
    if (name is! String || name.isEmpty) return null;
    final icon = result?['icon'];
    return LinkHandler(
      name: name,
      icon: icon is Uint8List && icon.isNotEmpty ? MemoryImage(icon) : null,
    );
  }
}

/// Linux: `xdg-mime` names the default handler's desktop entry, whose `Name`
/// and `Icon` keys give the rest.
///
/// The icon is looked up in the hicolor theme, which every app installs into
/// because it is the fallback theme, and then in pixmaps. PNG only: an app
/// that ships just an SVG gets its name but keeps the generic glyph, since
/// drawing SVG would mean a new dependency for one icon.
class LinuxLinkHandlerService extends CachingLinkHandlerService {
  LinuxLinkHandlerService({ProcessRunner? runProcess, this.environment})
    : _run = runProcess ?? Process.run,
      super(platform: 'linux');

  final ProcessRunner _run;

  /// The XDG variables to resolve data directories from; the process's own
  /// when null.
  final Map<String, String>? environment;

  static const _iconSizes = ['256x256', '128x128', '96x96', '64x64', '48x48'];

  @override
  Future<LinkHandler?> lookUp(Uri uri) async {
    final result = await _run('xdg-mime', [
      'query',
      'default',
      'x-scheme-handler/${uri.scheme}',
    ]).timeout(const Duration(seconds: 3));
    if (result.exitCode != 0) return null;
    final desktopId = result.stdout.toString().trim();
    if (!desktopId.endsWith('.desktop')) return null;

    final dataDirs = xdgDataDirs(environment);
    File? entry;
    for (final dir in dataDirs) {
      final candidate = File(path.join(dir, 'applications', desktopId));
      if (candidate.existsSync()) {
        entry = candidate;
        break;
      }
    }
    if (entry == null) return null;

    final keys = parseDesktopEntry(await entry.readAsString());
    final name = keys['Name'];
    if (name == null || name.isEmpty) return null;
    final icon = _iconFile(keys['Icon'], dataDirs);
    return LinkHandler(name: name, icon: icon == null ? null : FileImage(icon));
  }

  File? _iconFile(String? icon, List<String> dataDirs) {
    if (icon == null || icon.isEmpty) return null;
    if (path.isAbsolute(icon)) {
      final file = File(icon);
      return icon.endsWith('.png') && file.existsSync() ? file : null;
    }
    for (final dir in dataDirs) {
      for (final size in _iconSizes) {
        final file = File(
          path.join(dir, 'icons', 'hicolor', size, 'apps', '$icon.png'),
        );
        if (file.existsSync()) return file;
      }
    }
    for (final dir in dataDirs) {
      final file = File(path.join(dir, 'pixmaps', '$icon.png'));
      if (file.existsSync()) return file;
    }
    return null;
  }
}

/// The unlocalised keys of a desktop entry's `[Desktop Entry]` group.
@visibleForTesting
Map<String, String> parseDesktopEntry(String contents) {
  final keys = <String, String>{};
  var inEntry = false;
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inEntry = line == '[Desktop Entry]';
      continue;
    }
    if (!inEntry || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    final key = line.substring(0, equals).trim();
    // Name[fr] and the like: the plain key is what every entry has.
    if (key.contains('[')) continue;
    keys.putIfAbsent(key, () => line.substring(equals + 1).trim());
  }
  return keys;
}
