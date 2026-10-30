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
/// Kind, scheme and host - not the full URI, or every web link would be a
/// lookup of its own. The host stays in because Android routes by it: a
/// google.com/maps link opens Google Maps and a google.com/search link opens
/// the browser. The kind stays in for the same pair, which share a host.
String linkHandlerCacheKey(ClipLink link, String platform) {
  final uri = link.openUri(platform);
  return '${link.kind.name}:${uri.scheme}:${uri.host}';
}
