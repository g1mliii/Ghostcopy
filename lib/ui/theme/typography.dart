import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// GhostCopy typography styles
class GhostTypography {
  // Private constructor to prevent instantiation
  GhostTypography._();

  /// The declared design font. Kept const because the theme's TextTheme is a
  /// const tree; [uiFontFamily] is what actually reaches the screen.
  static const fontFamily = 'Inter';
  static const monoFontFamily = 'JetBrains Mono';

  static bool get _isApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// The UI font for the platform the app is running on.
  ///
  /// No font files are bundled, so 'Inter' has never resolved to anything - it
  /// silently falls through to whatever the platform's default is, which on
  /// Apple devices is already SF Pro. Naming it makes that a decision instead
  /// of an accident, and keeps iOS on SF Pro if Inter is ever bundled for
  /// Android. '.SF Pro Text' is the family Flutter's own Cupertino theme uses.
  static final String uiFontFamily = _isApple ? '.SF Pro Text' : fontFamily;

  /// Monospace font for code, JSON and JWT payloads. Menlo ships on every
  /// iOS and macOS release; JetBrains Mono is not bundled either.
  static final String codeFontFamily = _isApple ? 'Menlo' : monoFontFamily;

  static final TextStyle headline = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    fontFamily: uiFontFamily,
  );

  static final TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    fontFamily: uiFontFamily,
  );

  static final TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    fontFamily: uiFontFamily,
  );

  static final TextStyle mono = TextStyle(
    fontFamily: codeFontFamily,
    fontSize: 13,
  );
}
