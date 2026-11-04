import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/settings_service.dart';
import 'appearance.dart';

/// Shared palette with white mobile surfaces and dark desktop surfaces.
class GhostColors {
  GhostColors._();

  /// Mobile resolves its saved override against the current system brightness.
  static bool get isLight =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android) &&
      switch (appAppearance.value) {
        AppThemeMode.light => true,
        AppThemeMode.dark => false,
        AppThemeMode.system =>
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.light,
      };

  static Color get background =>
      isLight ? const Color(0xFFF2F2F7) : const Color(0xFF0F0F13);
  static Color get surface => isLight ? Colors.white : _darkSurface;
  static const _darkSurface = Color(0xFF19191F);
  static Color get surfaceLight =>
      isLight ? const Color(0xFFEAEAF0) : const Color(0xFF23232B);

  static const primary = Color(0xFF6670FF);
  static const primaryHover = Color(0xFF555CCB);
  static Color get successText => isLight ? const Color(0xFF216337) : success;
  static Color get warningText => isLight ? const Color(0xFF8A5700) : warning;
  static Color get errorText => isLight ? const Color(0xFFBA1A1A) : error;

  static const success = Color(0xFF3BA55C);
  static Color get accentSoft =>
      isLight ? const Color(0xFFEEEEFF) : const Color(0xFF292D55);
  static Color get accentText =>
      isLight ? const Color(0xFF484FB5) : const Color(0xFFAEB4FF);
  static Color get actionText => isLight ? const Color(0xFF484FB5) : primary;
  static const accentBorder = Color(0xFF555EA6);
  static const accentDisabled = Color(0x99555CCB);
  static Color get border =>
      isLight ? const Color(0xFFD1D1D6) : const Color(0xFF32323C);
  static Color get textPrimary =>
      isLight ? const Color(0xFF1C1C1E) : const Color(0xFFF5F6FA);
  static Color get textSecondary =>
      isLight ? const Color(0xFF636366) : const Color(0xFFB9BBBE);
  static Color get textMuted => isLight ? _lightMuted : _darkMuted;
  static const _lightMuted = Color(0xFF68686C);
  static const _darkMuted = Color(0xFF989CA9);

  static const warning = Color(0xFFFFB020);
  static const error = Color(0xFFEF5350);
  static Color get errorLight =>
      isLight ? const Color(0xFFBA1A1A) : const Color(0xFFFF8A80);
  static Color get glassBorder =>
      isLight ? _lightGlassBorder : _darkGlassBorder;
  static const _lightGlassBorder = Color(0x1F000000);
  static const _darkGlassBorder = Color(0x33FFFFFF);

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

  /// A palette colour at [alpha], made once per palette rather than on
  /// every access: (light, dark).
  static (Color, Color) _alphaPair(Color light, Color dark, double alpha) =>
      (light.withValues(alpha: alpha), dark.withValues(alpha: alpha));
  static Color _pick((Color, Color) pair) => isLight ? pair.$1 : pair.$2;

  static final _surfaceAlpha50 = _alphaPair(Colors.white, _darkSurface, 0.5);
  static final _surfaceAlpha70 = _alphaPair(Colors.white, _darkSurface, 0.7);
  static final _surfaceAlpha85 = _alphaPair(Colors.white, _darkSurface, 0.85);
  static final _surfaceAlpha95 = _alphaPair(Colors.white, _darkSurface, 0.95);
  static final _textMutedAlpha30 = _alphaPair(_lightMuted, _darkMuted, 0.3);
  static final _textMutedAlpha50 = _alphaPair(_lightMuted, _darkMuted, 0.5);
  static final _textMutedAlpha60 = _alphaPair(_lightMuted, _darkMuted, 0.6);
  static final _textMutedAlpha70 = _alphaPair(_lightMuted, _darkMuted, 0.7);
  static final _glassBorderAlpha30 = _alphaPair(
    _lightGlassBorder,
    _darkGlassBorder,
    0.3,
  );

  // Surface alpha variants (used in hover states, overlays)
  static Color get surfaceAlpha50 => _pick(_surfaceAlpha50);
  static Color get surfaceAlpha70 => _pick(_surfaceAlpha70);
  static Color get surfaceAlpha85 => _pick(_surfaceAlpha85);
  static Color get surfaceAlpha95 => _pick(_surfaceAlpha95);

  // Placeholder and disabled text variants
  static Color get textMutedAlpha30 => _pick(_textMutedAlpha30);
  static Color get textMutedAlpha50 => _pick(_textMutedAlpha50);
  static Color get textMutedAlpha60 => _pick(_textMutedAlpha60);
  static Color get textMutedAlpha70 => _pick(_textMutedAlpha70);

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
  static Color get glassBorderAlpha30 => _pick(_glassBorderAlpha30);
}
