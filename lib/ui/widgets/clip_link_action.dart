import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/clip_link.dart';
import '../../models/clipboard_item.dart';
import '../../services/impl/crash_reporting_service.dart';
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

/// The glyph a link clip shows in place of a thumbnail.
class ClipLinkGlyph extends StatelessWidget {
  const ClipLinkGlyph({
    required this.link,
    required this.size,
    required this.color,
    super.key,
  });

  final ClipLink link;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Icon(
    clipLinkIcon(link.kind),
    size: size,
    color: color,
    semanticLabel: link.kindLabel,
  );
}
