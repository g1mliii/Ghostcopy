import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/clip_link.dart';
import '../../models/clipboard_item.dart';
import '../../services/impl/crash_reporting_service.dart';
import '../../services/link_handler_service.dart';
import '../../utils/target_device_type.dart';

/// The icon for a kind of link, before anything is known about which app on
/// this device would open it.
IconData clipLinkIcon(ClipLinkKind kind) => switch (kind) {
  ClipLinkKind.web => Icons.public,
  ClipLinkKind.map => Icons.map_outlined,
  ClipLinkKind.email => Icons.mail_outline,
  ClipLinkKind.phone => Icons.phone_outlined,
};

/// The link [item] is, when it is a plain-text clip that is one.
///
/// HTML and Markdown clips are excluded even when short: their content is
/// markup, and a bare link in it has been formatted on purpose.
ClipLink? clipLinkFor(ClipboardItem item) =>
    item.contentType == ContentType.text ? ClipLink.detect(item.content) : null;

/// This device as a `device_type_enum` value, which is what [ClipLink] takes.
///
/// From defaultTargetPlatform rather than dart:io's Platform so a widget test
/// can stand in for any platform.
String get currentLinkPlatform => deviceTypeFor(defaultTargetPlatform);

/// Whether this device can open [link] at all - no Call button on Linux.
bool canOpenClipLink(ClipLink link) => link.canOpenOn(currentLinkPlatform);

/// Hands [link] to whatever this device opens that kind of link with.
///
/// Returns null when something took it, and otherwise what to tell the user,
/// so a caller only has to show it. Always an external application: a link
/// opened inside GhostCopy's own window would leave the user in a browser
/// with no address bar, inside a clipboard app.
Future<String?> openClipLink(ClipLink link) async {
  recordDiagnostic('ui', '${link.kindLabel} link opened');
  try {
    final opened = await launchUrl(
      link.openUri(currentLinkPlatform),
      mode: LaunchMode.externalApplication,
    );
    if (opened) return null;
  } on Exception catch (e) {
    debugPrint('[ClipLink] Could not open ${link.kind.name} link: $e');
  }
  return _openFailedMessage(link);
}

String _openFailedMessage(ClipLink link) => switch (link.kind) {
  ClipLinkKind.web => 'No browser could open this link',
  ClipLinkKind.map => 'No maps app could open this place',
  ClipLinkKind.email => 'No email app is set up on this device',
  ClipLinkKind.phone => 'This device cannot place calls',
};

/// What the Open control says: "Open in Google Maps" once this device's
/// [handler] is known, the kind's own wording ("Open in Maps") until then.
String clipLinkActionLabel(ClipLink link, LinkHandler? handler) =>
    handler == null ? link.actionLabel : 'Open in ${handler.name}';

/// Builds with this device's handler for [link] - null until the lookup
/// answers, and for good where it finds nothing - and again when it answers.
///
/// The one place a widget learns the handler, so the glyph, the Open
/// tooltip and the Open labels all change together when it arrives.
class ClipLinkHandlerBuilder extends StatefulWidget {
  const ClipLinkHandlerBuilder({
    required this.link,
    required this.builder,
    super.key,
  });

  final ClipLink link;
  final Widget Function(BuildContext context, LinkHandler? handler) builder;

  @override
  State<ClipLinkHandlerBuilder> createState() => _ClipLinkHandlerBuilderState();
}

class _ClipLinkHandlerBuilderState extends State<ClipLinkHandlerBuilder> {
  LinkHandler? _handler;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ClipLinkHandlerBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.uri != widget.link.uri) _resolve();
  }

  void _resolve() {
    final service = LinkHandlerService.instance;
    final link = widget.link;
    _handler = service.cachedHandlerFor(link);
    unawaited(
      service.handlerFor(link).then((handler) {
        // The service hands back one instance per app, so an unchanged
        // answer - a refresh after maxAge - rebuilds nothing.
        if (!mounted || widget.link.uri != link.uri || handler == _handler) {
          return;
        }
        setState(() => _handler = handler);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _handler);
}

/// A [Tooltip] saying [clipLinkActionLabel] for this device's handler.
class ClipLinkTooltip extends StatelessWidget {
  const ClipLinkTooltip({required this.link, required this.child, super.key});

  final ClipLink link;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipLinkHandlerBuilder(
    link: link,
    builder: (context, handler) =>
        Tooltip(message: clipLinkActionLabel(link, handler), child: child),
  );
}

/// [clipLinkActionLabel] as a Text, for this device's handler.
class ClipLinkActionText extends StatelessWidget {
  const ClipLinkActionText({required this.link, super.key});

  final ClipLink link;

  @override
  Widget build(BuildContext context) => ClipLinkHandlerBuilder(
    link: link,
    builder: (context, handler) => Text(clipLinkActionLabel(link, handler)),
  );
}

/// The glyph a link clip shows in place of a thumbnail: the icon of the app
/// on this device that Open launches, or the kind's generic icon where that
/// is not known (iOS, which cannot ask; an app with no readable icon; the
/// first frame of a lookup still in flight).
class ClipLinkGlyph extends StatelessWidget {
  const ClipLinkGlyph({
    required this.link,
    required this.size,
    required this.color,
    this.appIconSize,
    super.key,
  });

  final ClipLink link;

  /// The generic icon's size.
  final double size;
  final Color color;

  /// The app icon's size, when it should differ from [size]. An app icon is a
  /// filled square that carries its own padding, so it wants a little more
  /// room than a line glyph to look the same weight.
  final double? appIconSize;

  @override
  Widget build(BuildContext context) {
    Widget generic({String? semanticLabel}) => Icon(
      clipLinkIcon(link.kind),
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );

    return ClipLinkHandlerBuilder(
      link: link,
      builder: (context, handler) {
        if (handler case LinkHandler(:final name, icon: final icon?)) {
          final side = appIconSize ?? size;
          return Image(
            image: icon,
            width: side,
            height: side,
            semanticLabel: '${link.kindLabel}, opens in $name',
            // A file that has gone since it was found (an app uninstalled
            // while the history is open) falls back rather than drawing a
            // broken image.
            errorBuilder: (context, error, stackTrace) => generic(),
          );
        }
        return generic(semanticLabel: link.kindLabel);
      },
    );
  }
}
