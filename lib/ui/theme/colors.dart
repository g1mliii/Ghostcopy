import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Shared palette with white mobile surfaces and dark desktop surfaces.
class GhostColors {
  GhostColors._();

  /// Mobile uses the light palette, including shared dialogs and sheets.
  static bool get isLight =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static Color get background =>
      isLight ? const Color(0xFFF2F2F7) : const Color(0xFF0F0F13);
  static Color get surface => isLight ? Colors.white : const Color(0xFF19191F);
  static Color get surfaceLight =>
      isLight ? const Color(0xFFEAEAF0) : const Color(0xFF23232B);

  static const primary = Color(0xFF6670FF);
  static const primaryHover = Color(0xFF555CCB);
  static const success = Color(0xFF3BA55C);
  static Color get accentSoft =>
      isLight ? const Color(0xFFEEEEFF) : const Color(0xFF292D55);
  static Color get accentText =>
      isLight ? const Color(0xFF484FB5) : const Color(0xFFAEB4FF);
  static Color get actionText => isLight ? accentText : primary;
  static const accentBorder = Color(0xFF555EA6);
  static const accentDisabled = Color(0x99555CCB);
  static Color get border =>
      isLight ? const Color(0xFFD1D1D6) : const Color(0xFF32323C);
  static Color get textPrimary =>
      isLight ? const Color(0xFF1C1C1E) : const Color(0xFFF5F6FA);
  static Color get textSecondary =>
      isLight ? const Color(0xFF636366) : const Color(0xFFB9BBBE);
  static Color get textMuted =>
      isLight ? const Color(0xFF6C6C70) : const Color(0xFF989CA9);

  static const warning = Color(0xFFFFB020);
  static Color get warningLight =>
      isLight ? const Color(0xFF8A5700) : const Color(0xFFFFD54F);
  static const error = Color(0xFFEF5350);
  static Color get errorLight =>
      isLight ? const Color(0xFFBA1A1A) : const Color(0xFFFF8A80);
  static Color get glassBorder =>
      isLight ? const Color(0x1F000000) : const Color(0x33FFFFFF);

  // Cached primary alpha variants (avoid creating new Color objects per build)
  static final primaryAlpha10 = primary.withValues(alpha: 0.1);
  static final primaryAlpha15 = primary.withValues(alpha: 0.15);
  static final primaryAlpha20 = primary.withValues(alpha: 0.2);
  static final primaryAlpha30 = primary.withValues(alpha: 0.3);
  static final primaryAlpha50 = primary.withValues(alpha: 0.5);
  static final primaryAlpha70 = primary.withValues(alpha: 0.7);
  static final primaryAlpha80 = primary.withValues(alpha: 0.8);
  static final primaryAlpha90 = primary.withValues(alpha: 0.9);

  // Cached success alpha variants
  static final successAlpha20 = success.withValues(alpha: 0.2);

  // Surface alpha variants (used in hover states, overlays)
  static Color get surfaceAlpha50 => surface.withValues(alpha: 0.5);
  static Color get surfaceAlpha70 => surface.withValues(alpha: 0.7);
  static Color get surfaceAlpha85 => surface.withValues(alpha: 0.85);
  static Color get surfaceAlpha95 => surface.withValues(alpha: 0.95);

  // Placeholder and disabled text variants
  static Color get textMutedAlpha30 => textMuted.withValues(alpha: 0.3);
  static Color get textMutedAlpha50 => textMuted.withValues(alpha: 0.5);
  static Color get textMutedAlpha60 => textMuted.withValues(alpha: 0.6);
  static Color get textMutedAlpha70 => textMuted.withValues(alpha: 0.7);

  // Cached error alpha variants
  static final errorAlpha10 = error.withValues(alpha: 0.1);
  static final errorAlpha30 = error.withValues(alpha: 0.3);

  // Cached common Colors alpha variants (avoid creating in build methods)
  static final whiteAlpha10 = Colors.white.withValues(alpha: 0.1);
  static final whiteAlpha20 = Colors.white.withValues(alpha: 0.2);
  static final whiteAlpha60 = Colors.white.withValues(alpha: 0.6);
  static final whiteAlpha70 = Colors.white.withValues(alpha: 0.7);

  /// Dims a control while pressed on touch platforms.
  static final blackAlpha18 = Colors.black.withValues(alpha: 0.18);
  static final blackAlpha50 = Colors.black.withValues(alpha: 0.5);
  static final redAlpha10 = Colors.red.withValues(alpha: 0.1);
  static final redAlpha30 = Colors.red.withValues(alpha: 0.3);
  static final redDarkAlpha20 = Colors.red.shade900.withValues(alpha: 0.2);
  static final redLightAlpha30 = Colors.red.shade400.withValues(alpha: 0.3);

  // Glass border alpha variant
  static Color get glassBorderAlpha30 => glassBorder.withValues(alpha: 0.3);
}
