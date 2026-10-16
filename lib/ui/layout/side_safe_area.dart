import 'package:flutter/widgets.dart';

import '../theme/colors.dart';

/// Keeps a mobile screen's content clear of system UI on its left and right
/// edges, and paints the strip it gives up in the app background.
///
/// The screens only ever padded for the bottom: the AppBar takes care of the
/// top, and no phone had a side inset in portrait. The iPhone Duo does. On an
/// app built with the iOS 27.1 SDK it draws the status bar and camera as a
/// vertical strip down the right edge - 84pt on the cover display - over
/// whatever is under it, and the composer, send button and history ran
/// straight underneath. The notch does the same on an iPhone held sideways.
///
/// Apple's route is to respect the inset rather than hide the strip: there is
/// no API to remove it (the camera is hardware), and hiding the status bar
/// costs the user the clock and battery for nothing. So this takes the left
/// and right safe-area insets off once, above every route - screens, dialogs
/// and sheets alike - and leaves top and bottom to each screen, which already
/// draws its header up into the status bar and pads above the home indicator.
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
