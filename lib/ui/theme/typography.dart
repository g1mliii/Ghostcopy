import 'package:flutter/material.dart';

/// GhostCopy typography styles
class GhostTypography {
  // Private constructor to prevent instantiation
  GhostTypography._();

  static const fontFamily = 'Inter';
  static const monoFontFamily = 'JetBrains Mono';

  static const headline = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
    fontFamily: fontFamily,
  );

  static const body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    fontFamily: fontFamily,
  );

  static const caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    fontFamily: fontFamily,
  );

  static const mono = TextStyle(fontFamily: monoFontFamily, fontSize: 13);
}
