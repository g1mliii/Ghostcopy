import 'package:flutter/material.dart';

import '../platform_adaptive.dart';
import '../theme/colors.dart';

/// The one switch used everywhere, so Settings looks the same on every surface.
///
/// Only Android and desktop are scaled down. Material 3's switch is 52x32 and
/// overweight beside 13-14px type; CupertinoSwitch is already the size iOS
/// users know, and shrinking it would make it the odd one out on its own
/// platform.
///
/// Colour comes from AppTheme.switchTheme - call sites should not override the
/// thumb, or the "on" state ends up a purple thumb on a purple track.
class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({required this.value, required this.onChanged, super.key});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final control = Switch.adaptive(
      value: value,
      onChanged: onChanged,
      activeTrackColor: GhostColors.primary,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return Adaptive.isIOS
        ? control
        : Transform.scale(scale: 0.8, child: control);
  }
}
