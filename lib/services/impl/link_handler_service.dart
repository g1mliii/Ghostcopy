import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../models/clip_link.dart';
import '../../utils/xdg.dart';
import '../link_handler_service.dart';
import 'command_line_tool_service.dart' show ProcessRunner;

/// The caching every platform shares: one lookup per [cacheKeyFor], refreshed
/// after [maxAge] so a default app changed while GhostCopy sits in the tray
/// for a week is picked up, and one [LinkHandler] per app, so fifty links that
/// open in Chrome share one decoded icon. At most [maxEntries] keys are kept,
/// least recently used first out, so a tray session that sees thousands of
/// distinct links does not keep a lookup for every one.
abstract class CachingLinkHandlerService implements ILinkHandlerService {
  CachingLinkHandlerService({required this.platform});

  /// The `device_type_enum` value [ClipLink.openUri] is asked for.
  final String platform;

  static const maxAge = Duration(minutes: 10);
  static const maxEntries = 128;

  // Map literals keep insertion order: a key is moved to the end when used,
  // so the first is the least recently used.
  final _lookups = <String, ({DateTime at, Future<LinkHandler?> handler})>{};
  final _resolved = <String, LinkHandler?>{};
  final _byName = <String, LinkHandler>{};

  /// Which app opens [uri], or null if none, or none in particular.
  @protected
  Future<LinkHandler?> lookUp(Uri uri);

  /// The part of [uri] this platform's answer depends on - never the whole
  /// URI, or every web link would be a lookup of its own.
  String cacheKeyFor(Uri uri);

  @override
  Future<LinkHandler?> handlerFor(ClipLink link) {
    final uri = link.openUri(platform);
    final key = cacheKeyFor(uri);
    final now = clock.now();
    if (_lookups.remove(key) case final lookup?
        when now.difference(lookup.at) <= maxAge) {
      _lookups[key] = lookup;
      return lookup.handler;
    }
    late final Future<LinkHandler?> handler;
    handler = _lookUpSafely(uri).then((found) {
      final shared = found == null ? null : _shareHandler(found);
      // Only while this lookup is still the one wanted: one evicted
      // meanwhile stays out, so the two maps stay bounded together, and one
      // superseded by a refresh does not overwrite the newer answer.
      if (identical(_lookups[key]?.handler, handler)) {
        _resolved.remove(key);
        _resolved[key] = shared;
      }
      return shared;
    });
    _lookups[key] = (at: now, handler: handler);
    while (_lookups.length > maxEntries) {
      _resolved.remove(_lookups.keys.first);
      _lookups.remove(_lookups.keys.first);
    }
    return handler;
  }

  LinkHandler _shareHandler(LinkHandler found) {
    final previous = _byName[found.name];
    final icon = found.icon;
    final previousIcon = previous?.icon;
    // Native lookups return fresh byte arrays. Reuse the decoded image when
    // the pixels are unchanged, but let a missing or updated icon recover.
    if (previous != null &&
        (icon == previousIcon ||
            (icon is MemoryImage &&
                previousIcon is MemoryImage &&
                icon.scale == previousIcon.scale &&
                listEquals(icon.bytes, previousIcon.bytes)))) {
      return previous;
    }
    return _byName[found.name] = found;
  }

  @override
  LinkHandler? cachedHandlerFor(ClipLink link) =>
      _resolved[cacheKeyFor(link.openUri(platform))];

  /// An icon is decoration: a lookup that fails - no answer, a timeout, a
  /// platform or file error - leaves the generic glyph, never an error the
  /// user sees. An Error is a bug in the lookup, not a missing icon, and is
  /// left to surface; each platform turns malformed native data into null
  /// rather than throwing.
  Future<LinkHandler?> _lookUpSafely(Uri uri) async {
    try {
      return await lookUp(uri);
    } on Exception catch (e) {
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

  /// Both route web links by more than the host - google.com/maps opens
  /// Google Maps and google.com/search the browser, docs.google.com/document
  /// opens Docs and /spreadsheets Sheets. An Android intent filter can match a
  /// path at any depth, and a macOS universal link's associated-domains
  /// components can match the query and fragment too, so a web link keys on
  /// everything but the scheme's own defaults: path on Android, the whole URL
  /// on macOS. A `geo:` or `tel:` path is the place or number itself, so other
  /// schemes key on the scheme.
  @override
  String cacheKeyFor(Uri uri) {
    final web = uri.isScheme('https') || uri.isScheme('http');
    if (!web) return uri.scheme;
    if (platform == 'macos') return uri.toString();
    return '${uri.scheme}:${uri.host}${uri.path}';
  }

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

  /// xdg-mime associates a whole scheme with one app.
  @override
  String cacheKeyFor(Uri uri) => uri.scheme;

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
    final entry = [
      for (final dir in dataDirs)
        for (final relative in desktopEntryPaths(desktopId))
          File(path.join(dir, 'applications', relative)),
    ].where((file) => file.existsSync()).firstOrNull;
    if (entry == null) return null;

    final keys = parseDesktopEntry(await entry.readAsString());
    // The name the user's desktop shows, in their language.
    final name = localizedEntryValue(
      keys,
      'Name',
      environment ?? Platform.environment,
    );
    if (name == null || name.isEmpty) return null;
    final icon = _iconFile(keys['Icon'], dataDirs);
    return LinkHandler(name: name, icon: icon == null ? null : FileImage(icon));
  }

  /// Where under `applications/` the entry for [desktopId] can be.
  ///
  /// A desktop file ID is its path below `applications/` with each `/` made
  /// a `-`, so `kde4-kmail.desktop` may be `kde4/kmail.desktop`. Every way of
  /// reading the dashes back is a candidate, the literal name first; an ID
  /// with more than a few dashes is tried as written only.
  @visibleForTesting
  static List<String> desktopEntryPaths(String desktopId) {
    final parts = desktopId.split('-');
    if (parts.length == 1 || parts.length > 5) return [desktopId];
    var paths = [parts.first];
    for (final part in parts.skip(1)) {
      paths = [
        for (final prefix in paths) ...['$prefix-$part', '$prefix/$part'],
      ];
    }
    return paths;
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
