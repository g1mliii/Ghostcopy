import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../lifecycle_controller.dart';
import '../window_service.dart';

/// Concrete implementation of IWindowService using window_manager package
///
/// Manages the borderless Spotlight window with transparent background,
/// rounded corners, and show/hide functionality for desktop platforms.
///
/// Tray Mode Integration (ONLY pauses UI resources, NOT core functionality):
/// - WHEN window is hidden THEN pause UI animations (TickerProviders)
/// - WHEN window is shown THEN resume UI animations within 50ms
///
/// CRITICAL: Tray Mode does NOT pause:
/// - Realtime clipboard stream (must receive clips 24/7 from other devices)
/// - Hotkey listener (needed to wake the app)
/// - System tray (needed for user access)
///
/// Only register Pausable resources that are purely UI-related:
/// - AnimationControllers for fade effects, loading spinners
/// - Non-essential UI streams (search filters, etc.)
/// - DO NOT register Realtime clipboard sync stream as Pausable!
class WindowService implements IWindowService {
  WindowService({ILifecycleController? lifecycleController})
    : _lifecycleController = lifecycleController;

  final ILifecycleController? _lifecycleController;
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
      backgroundColor: Colors.transparent, // Start transparent to support tray menu
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden, // Borderless window
      windowButtonVisibility: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      // App launches hidden by default (Acceptance Criteria #1)
      // The callback is called after window is initialized but before show
      await windowManager.hide();
      _isVisible = false;
    });

    // Explicitly ensure window is hidden to prevent brief blank window on startup
    await windowManager.hide();
  }

  @override
  Future<void> showSpotlight() async {
    if (!_isDesktop()) {
      return;
    }

    // Exit Tray Mode BEFORE showing window to resume UI animations
    // Note: Only UI resources (AnimationControllers, etc.) are paused/resumed
    // Core services (Realtime stream, hotkeys) run 24/7
    _lifecycleController?.exitTrayMode();

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
    debugPrint('[WindowService] Hiding spotlight window');
    _isVisible = false;

    // Enter Tray Mode AFTER hiding window to pause UI animations
    // Note: Only pauses UI-related resources (AnimationControllers, etc.)
    // Core services continue running: Realtime stream, hotkeys, tray
    _lifecycleController?.enterTrayMode();
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
