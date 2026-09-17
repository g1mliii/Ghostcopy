import 'package:flutter/material.dart';

import '../platform_adaptive.dart';
import 'colors.dart';
import 'typography.dart';

/// GhostCopy application theme configuration
/// Inspired by Discord and Blip - modern, sleek dark theme with glassmorphism
class AppTheme {
  // Private constructor to prevent instantiation
  AppTheme._();

  /// Main dark theme for the application
  static ThemeData get darkTheme {
    return _withPlatformFont(
      ThemeData(
        // Base theme
        brightness: Brightness.dark,
        useMaterial3: true,

        // Ink ripples wash out to near-white against this palette's dark
        // surfaces, so presses read as a white flash. On desktop that is worth
        // removing outright, because hover already shows a control reacting
        // before it is pressed.
        //
        // Touch has no hover. Dropping the splash AND the highlight there left
        // taps with no feedback whatsoever - a row or chip looked inert until
        // its action finished, which on a slow network is long enough to make
        // people tap again. So mobile keeps a press state.
        //
        // The overlay is BLACK, not a tint. Every surface here is already dark,
        // so an additive overlay of any colour lightens it - that is the white
        // flash the default ripple gives and the reason splashes were removed
        // in the first place, and a brand-coloured one only makes it a purple
        // flash. Darkening reads as the control being pushed in, and matches
        // iOS, where a pressed control dims rather than glows.
        splashFactory: Adaptive.isDesktop
            ? NoSplash.splashFactory
            : InkRipple.splashFactory,
        splashColor: Adaptive.isDesktop
            ? Colors.transparent
            : GhostColors.blackAlpha18,
        highlightColor: Adaptive.isDesktop
            ? Colors.transparent
            : GhostColors.blackAlpha18,

        // Color scheme
        colorScheme: ColorScheme.dark(
          primary: GhostColors.primary,
          secondary: GhostColors.primary,
          surface: GhostColors.surface,
          error: Colors.red.shade400,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onError: Colors.white,
        ),

        // Scaffold
        scaffoldBackgroundColor: GhostColors.background,

        // App Bar
        appBarTheme: const AppBarTheme(
          // The header shares the page background rather than sitting on its own
          // grey bar. That leaves one meaning for the lighter surface colour -
          // "an elevated thing you interact with", i.e. cards and clips - instead
          // of it doing double duty as chrome, which is what made the top read as
          // a separate strip bolted onto the app.
          backgroundColor: GhostColors.background,
          foregroundColor: GhostColors.textPrimary,
          elevation: 0,
          // Material 3 tints an AppBar with surfaceTint once content scrolls
          // under it (scrolledUnderElevation defaults to 3). Left alone, the bar
          // would quietly turn grey again on the first scroll and put the seam
          // straight back.
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
        ),

        // Card
        cardTheme: CardThemeData(
          color: GhostColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),

        // Elevated Button
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: GhostColors.primary,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: GhostTypography.fontFamily,
            ),
          ),
        ),

        // Text Button
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: GhostColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFamily: GhostTypography.fontFamily,
            ),
          ),
        ),

        // Input Decoration
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: GhostColors.surfaceLight,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: GhostColors.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.red.shade400),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.red.shade400, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          hintStyle: const TextStyle(
            color: GhostColors.textMuted,
            fontFamily: GhostTypography.fontFamily,
          ),
          labelStyle: const TextStyle(
            color: GhostColors.textSecondary,
            fontFamily: GhostTypography.fontFamily,
          ),
        ),

        // Icon Theme
        iconTheme: const IconThemeData(
          color: GhostColors.textSecondary,
          size: 24,
        ),

        // Divider
        dividerTheme: const DividerThemeData(
          color: GhostColors.surfaceLight,
          space: 1,
        ),

        // Tooltip
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: GhostColors.surfaceLight,
            borderRadius: BorderRadius.circular(6),
          ),
          textStyle: const TextStyle(
            color: GhostColors.textPrimary,
            fontSize: 12,
            fontFamily: GhostTypography.fontFamily,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),

        // Snackbar
        snackBarTheme: SnackBarThemeData(
          backgroundColor: GhostColors.surfaceLight,
          contentTextStyle: const TextStyle(
            color: GhostColors.textPrimary,
            fontSize: 14,
            fontFamily: GhostTypography.fontFamily,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          behavior: SnackBarBehavior.floating,
        ),

        // Dialog
        dialogTheme: DialogThemeData(
          backgroundColor: GhostColors.surface,
          elevation: 8,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          titleTextStyle: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          contentTextStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textSecondary,
          ),
        ),

        // Text Theme
        textTheme: TextTheme(
          displayLarge: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          displayMedium: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          displaySmall: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          headlineLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          headlineMedium: GhostTypography.headline,
          headlineSmall: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          titleLarge: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          titleMedium: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          titleSmall: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          bodyLarge: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          bodyMedium: GhostTypography.body,
          bodySmall: GhostTypography.caption,
          labelLarge: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textPrimary,
          ),
          labelMedium: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textSecondary,
          ),
          labelSmall: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            fontFamily: GhostTypography.fontFamily,
            color: GhostColors.textMuted,
          ),
        ),

        // List Tile
        listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          iconColor: GhostColors.textSecondary,
          textColor: GhostColors.textPrimary,
        ),

        // Switch
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return Colors.white;
            }
            return GhostColors.textMuted;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return GhostColors.primary;
            }
            return GhostColors.surfaceLight;
          }),
        ),

        // Checkbox
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return GhostColors.primary;
            }
            return Colors.transparent;
          }),
          checkColor: WidgetStateProperty.all(Colors.white),
          side: const BorderSide(color: GhostColors.textMuted, width: 2),
        ),

        // Radio
        radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return GhostColors.primary;
            }
            return GhostColors.textMuted;
          }),
        ),
      ),
    );
  }

  /// Stamp the platform's UI font over a built theme.
  ///
  /// The styles above all name GhostTypography.fontFamily so the TextTheme can
  /// stay const; this replaces it in one pass rather than repeating a platform
  /// check 24 times. A no-op off Apple platforms.
  static ThemeData _withPlatformFont(ThemeData base) {
    final family = GhostTypography.uiFontFamily;
    if (family == GhostTypography.fontFamily) return base;
    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: family),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: family),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: family,
        ),
      ),
    );
  }
}
