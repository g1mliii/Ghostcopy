import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// The third-party sign-in options as a row of round logo buttons.
///
/// Replaces a stack of full-width "Continue with ..." buttons, which cost the
/// desktop Spotlight window - 400px tall - most of its height. Shared with the
/// mobile welcome screen so the two do not drift apart.
///
/// Logo-only is within both brands' rules: Apple's guidelines allow a
/// logo-only Sign in with Apple button, and Google's allow the "G" on its own.
/// Both are white circles of the same size, which also keeps Apple no less
/// prominent than Google, as App Review asks (guideline 4.8). Each carries a
/// tooltip and a screen-reader label, since the icon alone does not say what
/// the button does.
class SocialSignInButtons extends StatelessWidget {
  const SocialSignInButtons({
    required this.onGoogle,
    required this.onApple,
    required this.enabled,
    this.showApple = true,
    this.size = 52,
    super.key,
  });

  final VoidCallback onGoogle;
  final VoidCallback onApple;

  /// False while a sign-in is in flight, so a second tap cannot start another.
  final bool enabled;

  /// Hidden where Apple sign-in is not offered yet (Android).
  final bool showApple;

  /// Diameter. 52 keeps the touch target above the 48dp minimum.
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showApple) ...[
          _LogoButton(
            label: 'Continue with Apple',
            onTap: enabled ? onApple : null,
            size: size,
            child: Icon(Icons.apple, size: size * 0.5, color: Colors.black),
          ),
          const SizedBox(width: 16),
        ],
        _LogoButton(
          label: 'Continue with Google',
          onTap: enabled ? onGoogle : null,
          size: size,
          // A 96px raster of Google's standard four-colour "G", as used on its
          // sign-in buttons. Largest drawn is about 21 logical px, so this
          // covers a 3x screen with room to spare, without an SVG renderer
          // shipped for one fixed icon.
          child: Image.asset(
            'assets/icons/google_g.png',
            width: size * 0.4,
            height: size * 0.4,
          ),
        ),
      ],
    );
  }
}

class _LogoButton extends StatelessWidget {
  const _LogoButton({
    required this.label,
    required this.onTap,
    required this.size,
    required this.child,
  });

  final String label;
  final VoidCallback? onTap;
  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        child: Opacity(
          opacity: onTap == null ? 0.5 : 1,
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(
              side: BorderSide(color: GhostColors.surface),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(
                width: size,
                height: size,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
