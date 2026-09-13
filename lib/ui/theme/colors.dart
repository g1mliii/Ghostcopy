import 'package:flutter/material.dart';

/// GhostCopy color palette - dark theme with glassmorphism
class GhostColors {
  // Private constructor to prevent instantiation
  GhostColors._();

  // Background layers
  static const background = Color(0xFF0E0F13); // Deep black
  static const surface = Color(0xFF18191F); // Card surfaces
  static const surfaceLight = Color(0xFF22232B); // Elevated surfaces

  // Accent colors
  static const primary = Color(0xFF6670FF); // Purple-blue accent
  static const primaryHover = Color(0xFF4752C4);
  static const success = Color(0xFF3BA55C); // Green for confirmations

  /// Fill for a SELECTED control (chips, toggles). A tint rather than the full
  /// accent, so the Send button stays the only saturated purple on screen.
  static const accentSoft = Color(0xFF292D55);

  /// Text and icons on [accentSoft], and for accent-coloured metadata. Light
  /// enough to stay legible on the soft fill, which white is not.
  static const accentText = Color(0xFFAEB4FF);

  /// Border for a selected or focused control.
  static const accentBorder = Color(0xFF555EA6);

  /// Disabled primary button.
  static const accentDisabled = Color(0x99555CCB);

  /// Hairline between grouped rows and around surfaces. An opaque grey rather
  /// than the translucent glassBorder, so stacked rows in a grouped list do
  /// not accumulate brightness where they meet.
  static const border = Color(0xFF30323C);

  // Text
  static const textPrimary = Color(0xFFF5F6FA);
  static const textSecondary = Color(0xFFB9BBBE);
  static const textMuted = Color(0xFF989CA9);

  // Semantic colors for status/alerts
  static const warning = Color(0xFFFFB020); // Amber-like for warnings
  static const warningLight = Color(0xFFFFD54F); // Lighter warning
  static const error = Color(0xFFEF5350); // Red for errors
  static const errorLight = Color(0xFFFF8A80); // Lighter error text

  // Glassmorphism
  static const glassBackground = Color(0x1AFFFFFF); // 10% white
  static const glassBorder = Color(0x33FFFFFF); // 20% white

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
  static final successAlpha15 = success.withValues(alpha: 0.15);
  static final successAlpha20 = success.withValues(alpha: 0.2);

  // Cached surface alpha variants (used in hover states, overlays)
  static final surfaceAlpha50 = surface.withValues(alpha: 0.5);
  static final surfaceAlpha70 = surface.withValues(alpha: 0.7);
  static final surfaceAlpha85 = surface.withValues(alpha: 0.85);
  static final surfaceAlpha95 = surface.withValues(alpha: 0.95);

  // Cached textMuted alpha variants (used in placeholders, disabled states)
  static final textMutedAlpha30 = textMuted.withValues(alpha: 0.3);
  static final textMutedAlpha50 = textMuted.withValues(alpha: 0.5);
  static final textMutedAlpha60 = textMuted.withValues(alpha: 0.6);
  static final textMutedAlpha70 = textMuted.withValues(alpha: 0.7);

  // Cached error alpha variants
  static final errorAlpha10 = error.withValues(alpha: 0.1);
  static final errorAlpha30 = error.withValues(alpha: 0.3);

  // Cached common Colors alpha variants (avoid creating in build methods)
  static final whiteAlpha10 = Colors.white.withValues(alpha: 0.1);
  static final whiteAlpha20 = Colors.white.withValues(alpha: 0.2);
  static final whiteAlpha60 = Colors.white.withValues(alpha: 0.6);
  static final whiteAlpha70 = Colors.white.withValues(alpha: 0.7);
  static final blackAlpha30 = Colors.black.withValues(alpha: 0.3);
  static final blackAlpha50 = Colors.black.withValues(alpha: 0.5);
  static final redAlpha10 = Colors.red.withValues(alpha: 0.1);
  static final redAlpha30 = Colors.red.withValues(alpha: 0.3);
  static final redDarkAlpha20 = Colors.red.shade900.withValues(alpha: 0.2);
  static final redDarkAlpha30 = Colors.red.shade900.withValues(alpha: 0.3);
  static final redLightAlpha30 = Colors.red.shade400.withValues(alpha: 0.3);

  // Cached glassBorder alpha variant
  static final glassBorderAlpha30 = glassBorder.withValues(alpha: 0.3);
}
