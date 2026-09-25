import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import '../../ui/theme/colors.dart';

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
  WindowService({this._lifecycleController});

  final ILifecycleController? _lifecycleController;
  bool _isVisible = false;

  // Spotlight window dimensions from CLAUDE.md
  static const double _windowWidth = 500;
  static const double _windowHeight = 400;

  /// Breathing room left around a grown window, so it does not sit flush
  /// against the edges of the work area.
  static const double _workAreaMargin = 40;

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
      backgroundColor:
          Colors.transparent, // Start transparent to support tray menu
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

  /// Set by [setFramelessForTrayMenu], cleared once [showSpotlight] has put
  /// the frame back.
  bool _framelessForTrayMenu = false;

  @override
  Future<void> setFramelessForTrayMenu() async {
    _framelessForTrayMenu = true;
    await windowManager.setAsFrameless();
    // Topmost, or the menu loses the z-order fight it is guaranteed to have.
    //
    // The tray menu is an ordinary Flutter window rather than a native menu,
    // and right-clicking a tray icon is very often done from inside the
    // notification-area flyout - which is a system window that sits above
    // ordinary ones. So the menu opened behind the very flyout the click came
    // from and was invisible. Other tray apps look "detached" in the same way;
    // the difference is that theirs draw on top. Cleared in showSpotlight, so
    // the Spotlight itself is unaffected.
    await windowManager.setAlwaysOnTop(true);
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
    await windowManager.setBackgroundColor(GhostColors.surface);

    // Hide to avoid warping during resize
    await windowManager.hide();

    // Undo the tray menu's setAsFrameless(). On Windows that flag makes
    // window_manager hand the whole window to Flutter, dropping the resize
    // borders TitleBarStyle.hidden keeps - so after the first right-click on
    // the tray the Spotlight came back a different size and could no longer
    // be resized from its edges. setTitleBarStyle is the only call that
    // clears the flag, and windowButtonVisibility must stay false or it
    // brings the caption buttons back. Here rather than when the menu closes
    // because the menu has several exits (Settings, the hotkey) that go
    // straight to this method; gated so an ordinary hotkey press does not
    // pay for a frame change.
    if (_framelessForTrayMenu) {
      _framelessForTrayMenu = false;
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      // The menu needed to be topmost; the Spotlight does not, and leaving it
      // set would pin the whole app over everything else for the rest of the
      // session. Same gate, same reason: this is where the tray menu's window
      // changes are undone.
      await windowManager.setAlwaysOnTop(false);
    }

    // Set to Spotlight size and center (do this while hidden)
    await windowManager.setSize(const Size(_windowWidth, _windowHeight));
    await windowManager.center();

    // Show and focus
    await windowManager.show();
    await windowManager.focus();
    _isVisible = true;
    debugPrint('[WindowService] Spotlight shown');
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
  Future<void> growToHeight(double height) async {
    if (!_isDesktop()) return;
    // Resized in place rather than hidden first: the window is already on
    // screen here, and hiding it would dismiss the dialog that asked to grow.
    await windowManager.setSize(
      Size(_windowWidth, await _clampToWorkArea(height)),
    );
    await windowManager.center();
  }

  /// The tallest window that still fits on the display the window is on.
  ///
  /// A caller asks for the height its content wants, which on a short display
  /// is taller than the screen. Centring a window taller than the work area
  /// pushes its top and bottom off both edges, and the content cannot be
  /// scrolled back into view: the dialog lays out against the window it was
  /// given, so from its point of view everything fits and its scroll view
  /// never gets anything to scroll. Clamping here means the window stays on
  /// screen and the content becomes genuinely scrollable.
  ///
  /// Uses the work area rather than the full display, so the result excludes
  /// the Windows taskbar and the macOS menu bar and Dock.
  Future<double> _clampToWorkArea(double height) async {
    try {
      // Independent platform-channel round trips, so they go together.
      final (displays, bounds) = await (
        screenRetriever.getAllDisplays(),
        windowManager.getBounds(),
      ).wait;
      final display =
          displayContaining(displays, bounds.center) ??
          await screenRetriever.getPrimaryDisplay();

      return clampHeightToDisplay(height, display);
    } on Object catch (e) {
      // Never let a display query stop the resize - an unclamped window is a
      // cosmetic problem, a dialog that refuses to open is not.
      debugPrint('[WindowService] Could not read work area: $e');
      return height;
    }
  }

  /// The display [point] falls on, or null if none of them contain it.
  ///
  /// Matters on multi-monitor setups, where clamping to the primary display
  /// would size the window for a screen it is not on. Returns null rather than
  /// guessing when the point is outside every display - a window straddling
  /// two screens, or a platform that does not report display positions - so
  /// the caller can fall back to the primary display.
  @visibleForTesting
  static Display? displayContaining(List<Display> displays, Offset point) {
    for (final display in displays) {
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      final rect = Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
      if (rect.contains(point)) return display;
    }
    return null;
  }

  /// [height], reduced to what actually fits on [display].
  ///
  /// Reads visibleSize - the work area - in preference to the full display
  /// size, so the result excludes the Windows taskbar and the macOS menu bar
  /// and Dock. Falls back to the full size where the platform does not report
  /// a work area, and returns the requested height untouched when there is
  /// nothing trustworthy to measure against, since a slightly oversized window
  /// beats refusing to resize at all.
  @visibleForTesting
  static double clampHeightToDisplay(double height, Display? display) {
    final available = display?.visibleSize?.height ?? display?.size.height;
    if (available == null || available <= 0) return height;

    // A work area smaller than the margin would otherwise produce a zero or
    // negative height, which setSize rejects, so the margin is dropped rather
    // than applied in that case.
    final usable = available - _workAreaMargin;
    return math.min(height, usable > 0 ? usable : available);
  }

  @override
  Future<void> restoreSpotlightSize() async {
    if (!_isDesktop()) return;
    await windowManager.setSize(const Size(_windowWidth, _windowHeight));
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
