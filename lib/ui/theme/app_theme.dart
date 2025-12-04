import 'package:flutter/material.dart';
import 'colors.dart';
import 'typography.dart';

/// GhostCopy application theme configuration
/// Inspired by Discord and Blip - modern, sleek dark theme with glassmorphism
class AppTheme {
  // Private constructor to prevent instantiation
  AppTheme._();

  /// Main dark theme for the application
  static ThemeData get darkTheme {
    return ThemeData(
      // Base theme
      brightness: Brightness.dark,
      useMaterial3: true,

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
        backgroundColor: GhostColors.surface,
        foregroundColor: GhostColors.textPrimary,
        elevation: 0,
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Elevated Button
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: GhostColors.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      textTheme: const TextTheme(
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
    );
  }

  /// Glassmorphism container decoration
  static BoxDecoration get glassDecoration {
    return BoxDecoration(
      color: GhostColors.glassBackground,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: GhostColors.glassBorder),
    );
  }

  /// Glassmorphism container decoration with custom radius
  static BoxDecoration glassDecorationWithRadius(double radius) {
    return BoxDecoration(
      color: GhostColors.glassBackground,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: GhostColors.glassBorder),
    );
  }

  /// Card shadow for elevated surfaces
  static List<BoxShadow> get cardShadow {
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.2),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];
  }

  /// Spotlight window shadow
  static List<BoxShadow> get spotlightShadow {
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.3),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ];
  }
}
