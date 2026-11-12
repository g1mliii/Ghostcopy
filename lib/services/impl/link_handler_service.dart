import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../../models/clip_link.dart';
import '../link_handler_service.dart';
export 'linux_link_handler.dart';

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

  /// The parts of [uri] that can change the application chosen by the OS.
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
      final oldest = _lookups.keys.first;
      _resolved.remove(oldest);
      _lookups.remove(oldest);
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

  /// Web routing can depend on the query and fragment as well as the path:
  /// Android Dynamic App Links and macOS universal links both support them.
  /// The bounded LRU limits the extra entries. Other schemes use the scheme.
  @override
  String cacheKeyFor(Uri uri) => uri.isScheme('https') || uri.isScheme('http')
      ? uri.toString()
      : uri.scheme;

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
