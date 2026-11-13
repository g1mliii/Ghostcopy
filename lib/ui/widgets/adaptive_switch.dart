import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The one switch used everywhere, so Settings looks the same on every surface.
///
/// Only Android and desktop are scaled down. Material 3's switch is 52x32 and
/// overweight beside 13-14px type; CupertinoSwitch is already the size iOS
/// users know, and shrinking it would make it the odd one out on its own
/// platform.
///
/// Material colours come from AppTheme.switchTheme; the native Apple control
/// uses the same GhostColors tokens. Call sites should not override the thumb.
class AdaptiveSwitch extends StatelessWidget {
  const AdaptiveSwitch({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    // Switch.adaptive in the pinned SDK paints an Apple-looking Material switch
    // that can null-assert on its first mid-animation paint (Flutter #179532).
    final control = apple
        ? CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: GhostColors.primary,
            inactiveTrackColor: GhostColors.surfaceLight,
            thumbColor: Colors.white,
            inactiveThumbColor: GhostColors.textMuted,
          )
        : Switch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: GhostColors.primary,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );

    return platform == TargetPlatform.iOS
        ? control
        : Transform.scale(scale: 0.8, child: control);
  }
}
