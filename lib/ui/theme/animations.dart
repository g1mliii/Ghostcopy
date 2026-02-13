import 'package:flutter/material.dart';

/// GhostCopy animation duration constants
///
/// Use these constants instead of inline Duration values for consistency:
/// - Fast: micro-interactions (hover states, small transitions)
/// - Normal: standard UI transitions (button presses, small panels)
/// - Slow: larger transitions (panels sliding, fade effects)
/// - Panel: slide-in/out panels (settings, history)
class GhostAnimations {
  // Private constructor to prevent instantiation
  GhostAnimations._();

  /// Fast micro-interactions (150ms)
  static const Duration fast = Duration(milliseconds: 150);

  /// Standard UI transitions (200ms)
  static const Duration normal = Duration(milliseconds: 200);

  /// Larger transitions (300ms)
  static const Duration slow = Duration(milliseconds: 300);

  /// Panel slide animations (250ms)
  static const Duration panel = Duration(milliseconds: 250);

  /// Standard animation curve for most transitions
  static const Curve defaultCurve = Curves.easeOutCubic;

  /// Curve for entrance animations
  static const Curve entranceCurve = Curves.easeOut;

  /// Curve for exit animations
  static const Curve exitCurve = Curves.easeIn;
}
