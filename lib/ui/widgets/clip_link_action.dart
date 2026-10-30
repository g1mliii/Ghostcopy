import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/clip_link.dart';
import '../../models/clipboard_item.dart';
import '../../services/impl/crash_reporting_service.dart';
import '../../services/link_handler_service.dart';

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
String get currentLinkPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.macOS => 'macos',
  TargetPlatform.windows => 'windows',
  TargetPlatform.linux || TargetPlatform.fuchsia => 'linux',
};

/// Whether this device can open [link] at all - no Call button on Linux.
bool canOpenClipLink(ClipLink link) => link.canOpenOn(currentLinkPlatform);

/// Hands [link] to whatever this device opens that kind of link with.
///
/// Returns false when nothing took it, so the caller can say so. Always an
/// external application: a link opened inside GhostCopy's own window would
/// leave the user in a browser with no address bar, inside a clipboard app.
Future<bool> openClipLink(ClipLink link) async {
  recordDiagnostic('ui', '${link.kindLabel} link opened');
  try {
    return await launchUrl(
      link.openUri(currentLinkPlatform),
      mode: LaunchMode.externalApplication,
    );
  } on Exception catch (e) {
    debugPrint('[ClipLink] Could not open ${link.kind.name} link: $e');
    return false;
  }
}

/// What to say when [openClipLink] returns false.
String clipLinkOpenFailedMessage(ClipLink link) => switch (link.kind) {
  ClipLinkKind.web => 'No browser could open this link',
  ClipLinkKind.map => 'No maps app could open this place',
  ClipLinkKind.email => 'No email app is set up on this device',
  ClipLinkKind.phone => 'This device cannot place calls',
};

/// What the Open control says: "Open in Google Maps" once this device's
/// handler is known, the kind's own wording ("Open in Maps") until then.
String clipLinkActionLabel(ClipLink link) {
  final handler = LinkHandlerService.instance.cachedHandlerFor(link);
  return handler == null ? link.actionLabel : 'Open in ${handler.name}';
}

/// A [Tooltip] saying [clipLinkActionLabel], which rebuilds once this
/// device's handler is known.
///
/// The label is read from the handler cache, and the row that holds the Open
/// button builds before the lookup [ClipLinkGlyph] starts has answered; only
/// the glyph rebuilds when it does, so a plain Tooltip would keep "Open link"
/// where the row's own glyph already shows Chrome.
class ClipLinkTooltip extends StatefulWidget {
  const ClipLinkTooltip({required this.link, required this.child, super.key});

  final ClipLink link;
  final Widget child;

  @override
  State<ClipLinkTooltip> createState() => _ClipLinkTooltipState();
}

class _ClipLinkTooltipState extends State<ClipLinkTooltip> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ClipLinkTooltip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.uri != widget.link.uri) _resolve();
  }

  void _resolve() {
    final service = LinkHandlerService.instance;
    final link = widget.link;
    if (service.cachedHandlerFor(link) != null) return;
    unawaited(
      service.handlerFor(link).then((handler) {
        if (handler == null || !mounted || widget.link.uri != link.uri) return;
        setState(() {});
      }),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Tooltip(message: clipLinkActionLabel(widget.link), child: widget.child);
}

/// The glyph a link clip shows in place of a thumbnail: the icon of the app
/// on this device that Open launches, or the kind's generic icon where that
/// is not known (iOS, which cannot ask; an app with no readable icon; the
/// first frame of a lookup still in flight).
class ClipLinkGlyph extends StatefulWidget {
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
  State<ClipLinkGlyph> createState() => _ClipLinkGlyphState();
}

class _ClipLinkGlyphState extends State<ClipLinkGlyph> {
  LinkHandler? _handler;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ClipLinkGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.link.uri != widget.link.uri) _resolve();
  }

  void _resolve() {
    final service = LinkHandlerService.instance;
    final link = widget.link;
    _handler = service.cachedHandlerFor(link);
    unawaited(
      service.handlerFor(link).then((handler) {
        if (!mounted || widget.link.uri != link.uri || handler == _handler) {
          return;
        }
        setState(() => _handler = handler);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final handler = _handler;
    final icon = handler?.icon;
    if (handler == null || icon == null) {
      return Icon(
        clipLinkIcon(widget.link.kind),
        size: widget.size,
        color: widget.color,
        semanticLabel: widget.link.kindLabel,
      );
    }
    final side = widget.appIconSize ?? widget.size;
    return Image(
      image: icon,
      width: side,
      height: side,
      semanticLabel: '${widget.link.kindLabel}, opens in ${handler.name}',
      // A file that has gone since it was found (an app uninstalled while
      // the history is open) falls back rather than drawing a broken image.
      errorBuilder: (context, error, stackTrace) => Icon(
        clipLinkIcon(widget.link.kind),
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}
