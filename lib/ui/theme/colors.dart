import 'package:flutter/material.dart';

/// GhostCopy color palette - dark theme with glassmorphism
class GhostColors {
  // Private constructor to prevent instantiation
  GhostColors._();

  // Background layers
  static const background = Color(0xFF0D0D0F); // Deep black
  static const surface = Color(0xFF1A1A1D); // Card surfaces
  static const surfaceLight = Color(0xFF2A2A2D); // Elevated surfaces

  // Accent colors
  static const primary = Color(0xFF5865F2); // Discord-like purple-blue
  static const primaryHover = Color(0xFF4752C4);
  static const success = Color(0xFF3BA55C); // Green for confirmations

  // Text
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFB9BBBE);
  static const textMuted = Color(0xFF72767D);

  // Semantic colors for status/alerts
  static const warning = Color(0xFFFFB020); // Amber-like for warnings
  static const warningLight = Color(0xFFFFD54F); // Lighter warning
  static const error = Color(0xFFEF5350); // Red for errors
  static const errorLight = Color(0xFFFF8A80); // Lighter error text

  // Glassmorphism
  static const glassBackground = Color(0x1AFFFFFF); // 10% white
  static const glassBorder = Color(0x33FFFFFF); // 20% white
}
