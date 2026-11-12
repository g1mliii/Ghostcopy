import 'package:flutter/widgets.dart';

import '../theme/colors.dart';

/// Keeps a mobile screen's content clear of system UI on its left and right
/// edges, and paints the strip it gives up in the app background.
///
/// Apply this inside each mobile route, around the screen content. Wrapping
/// the Navigator would move its iOS back-gesture detector away from the
/// physical screen edge. Dialogs and sheets handle their own safe areas.
/// Top and bottom insets remain available to each screen's AppBar and body.
///
/// The background is the same colour as the screens and their AppBars, so the
/// strip reads as the edge of the app rather than a black bar beside it.
class SideSafeArea extends StatelessWidget {
  const SideSafeArea({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: GhostColors.background,
    child: SafeArea(top: false, bottom: false, child: child),
  );
}
