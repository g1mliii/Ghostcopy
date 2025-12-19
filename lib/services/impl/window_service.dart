import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import '../window_service.dart';

/// Concrete implementation of IWindowService using window_manager package
///
/// Manages the borderless Spotlight window with transparent background,
/// rounded corners, and show/hide functionality for desktop platforms.
class WindowService implements IWindowService {
  bool _isVisible = false;

  // Spotlight window dimensions from CLAUDE.md
  static const double _windowWidth = 500;
  static const double _windowHeight = 400;

  @override
  bool get isVisible => _isVisible;

  @override
  Future<void> initialize() async {
    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    await windowManager.ensureInitialized();

    // Configure window options for borderless Spotlight UI
    const windowOptions = WindowOptions(
      size: Size(_windowWidth, _windowHeight),
      center: true,
      backgroundColor: Color(0xFF1A1A1D), // Solid surface color
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden, // Borderless window
      windowButtonVisibility: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      // App launches hidden by default (Acceptance Criteria #1)
      await windowManager.hide();
      _isVisible = false;
    });
  }

  @override
  Future<void> showSpotlight() async {
    if (!_isDesktop()) return;

    // Set background color FIRST before any visibility changes
    await windowManager.setBackgroundColor(const Color(0xFF1A1A1D));

    // Hide to avoid warping during resize
    await windowManager.hide();

    // Set to Spotlight size and center (do this while hidden)
    await windowManager.setSize(const Size(_windowWidth, _windowHeight));
    await windowManager.center();

    // Show and focus
    await windowManager.show();
    await windowManager.focus();
    _isVisible = true;
  }

  @override
  Future<void> hideSpotlight() async {
    if (!_isDesktop()) return;

    await windowManager.hide();
    _isVisible = false;
  }

  @override
  Future<void> centerWindow() async {
    if (!_isDesktop()) return;
    await windowManager.center();
  }

  @override
  Future<void> focusWindow() async {
    if (!_isDesktop()) return;
    await windowManager.focus();
  }

  @override
  Future<void> dispose() async {
    // window_manager doesn't require explicit disposal.
    // Keep this method so callers can dispose services uniformly.
    // Guard against unexpected errors during shutdown to avoid crashes.
    try {
      // No explicit resources to free for window_manager
    } on Object catch (e, st) {
      // Swallow and log any errors during app shutdown
      debugPrint('WindowService.dispose error: $e\n$st');
    }
  }

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
