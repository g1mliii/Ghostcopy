import 'package:flutter/material.dart';

/// Abstract interface for toast window service
abstract class IToastWindowService {
  /// Show the toast window with content
  Future<void> showToast(Widget content, {Duration duration});

  /// Hide the toast window
  Future<void> hideToast();

  /// Initialize the toast window
  Future<void> initialize();

  /// Dispose and clean up
  void dispose();
}
