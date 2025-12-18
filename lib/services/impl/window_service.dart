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
      backgroundColor: Colors.transparent,
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

    // Reset to Spotlight size
    await windowManager.setSize(const Size(_windowWidth, _windowHeight));
    await centerWindow();
    await windowManager.show();
    await focusWindow();
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
    // window_manager doesn't require explicit disposal
    // This method is here for consistency with other services
  }

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
