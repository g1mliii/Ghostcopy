import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/clip_link.dart';
import 'impl/link_handler_service.dart';
import 'impl/windows_link_handler.dart';

/// The app on this device that a link would open in: its name and its icon.
@immutable
class LinkHandler {
  const LinkHandler({required this.name, this.icon});

  /// As the system names it: "Google Maps", "Safari", "Outlook".
  final String name;

  /// Null when the app is known but its icon could not be read - an SVG-only
  /// Linux icon theme, a packaged Windows app whose logo did not resolve.
  final ImageProvider? icon;
}

/// Finds which app on this device opens a [ClipLink], so the clip can show
/// that app's own icon - Google Maps on one phone, Waze on another, Safari on
/// the Mac - instead of a generic globe or map.
///
/// It asks about the URI [ClipLink.openUri] produces for this platform, which
/// is the one Open hands over, so the icon is always the app that tapping Open
/// actually launches. Nothing about the sender is involved: the same clip
/// shows a different icon on every device it reaches, and that is the point.
///
/// iOS has no API for this - an app cannot ask which app handles a URL, nor
/// read another app's icon - so there it answers null and the clip keeps the
/// generic glyph.
abstract class ILinkHandlerService {
  /// Answered and cached per [cacheKey], so a history of fifty web links asks
  /// the system once.
  Future<LinkHandler?> handlerFor(ClipLink link);

  /// What [handlerFor] already answered for [link], or null if it has not
  /// (or found nothing). Lets a widget draw the right icon on its first frame
  /// instead of flashing the generic one while a Future completes.
  LinkHandler? cachedHandlerFor(ClipLink link);
}

/// The process-wide [ILinkHandlerService].
///
/// A static rather than a locator registration so the history rows, which
/// several tests pump without a locator, can draw without one; tests swap it
/// through [instance].
class LinkHandlerService {
  LinkHandlerService._();

  static ILinkHandlerService? _instance;

  static ILinkHandlerService get instance => _instance ??= _forPlatform();

  @visibleForTesting
  static set instance(ILinkHandlerService? service) => _instance = service;

  static ILinkHandlerService _forPlatform() {
    if (kIsWeb) return const NoLinkHandlerService();
    if (Platform.isMacOS) return ChannelLinkHandlerService(platform: 'macos');
    if (Platform.isAndroid) {
      return ChannelLinkHandlerService(platform: 'android');
    }
    if (Platform.isWindows) return WindowsLinkHandlerService();
    if (Platform.isLinux) return LinuxLinkHandlerService();
    return const NoLinkHandlerService();
  }
}

/// The cache key for [link]'s handler on [platform].
///
/// Kind and scheme, never the full URI, or every web link would be a lookup
/// of its own. Beyond that it holds what the platform routes by:
///
/// - Android routes by host and path - a google.com/maps link opens Google
///   Maps and google.com/search the browser; docs.google.com/document opens
///   Docs and docs.google.com/spreadsheets opens Sheets - so for a web link
///   the host and the first path segment are in. The kind is in for the
///   first pair, which share a host. A `geo:` or `tel:` path is the place or
///   number itself, so those go by scheme.
/// - macOS answers by host at most, so the host is in.
/// - Windows and Linux associate a whole scheme with one app and their
///   lookups read nothing else, so more would only repeat the same lookup -
///   icon extraction included - for every site in the history.
String linkHandlerCacheKey(ClipLink link, String platform) {
  final uri = link.openUri(platform);
  final key = '${link.kind.name}:${uri.scheme}';
  return switch (platform) {
    'windows' || 'linux' => key,
    'android' when uri.isScheme('https') || uri.isScheme('http') =>
      '$key:${uri.host}/${uri.pathSegments.isEmpty ? '' : uri.pathSegments.first}',
    'android' => key,
    _ => '$key:${uri.host}',
  };
}
