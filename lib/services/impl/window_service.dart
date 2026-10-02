import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  DateTime? _hideStartedAt;
  DateTime? _blurredAt;

  // Spotlight window dimensions from CLAUDE.md
  static const double _windowWidth = 500;
  static const double _windowHeight = 400;

  /// Breathing room left around a grown window, so it does not sit flush
  /// against the edges of the work area.
  static const double _workAreaMargin = 40;

  @override
  bool get isVisible => _isVisible;

  @override
  bool hiddenWithin(Duration window) {
    final at = _hideStartedAt;
    return at != null && DateTime.now().difference(at) < window;
  }

  @override
  void noteBlur() => _blurredAt = DateTime.now();

  @override
  bool blurredWithin(Duration window) {
    final at = _blurredAt;
    return at != null && DateTime.now().difference(at) < window;
  }

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

  /// Whether the Spotlight is pinned open, as SpotlightViewModel last said.
  /// Pinned, it keeps its place and the hotkey only brings it forward.
  bool _pinned = false;

  /// Whether the pin also keeps it above other windows. Kept so
  /// [showSpotlight] can put topmost back after the tray menu.
  bool _onTop = false;

  /// Topmost is wanted by the tray menu and by the on-top pin; derived from
  /// both rather than set by each, so neither has to undo the other.
  Future<void> _applyTopmost() =>
      windowManager.setAlwaysOnTop(_framelessForTrayMenu || _onTop);

  /// Whether the app is in the app switcher right now - Cmd-Tab and the Dock
  /// on macOS, Alt-Tab and the taskbar on Windows. It starts out of both
  /// (LSUIElement, and skipTaskbar in [initialize]).
  bool _inAppSwitcher = false;

  /// An ordinary pin makes the Spotlight a normal window, and a normal window
  /// is one you can Cmd-Tab or Alt-Tab back to once another app covers it.
  /// Hidden, or lent to the tray menu, it is the tray utility again, with no
  /// Dock icon or taskbar button standing for nothing. The on-top pin needs
  /// none of it - it cannot be covered.
  ///
  /// Leaving waits for the window to be off screen: switching from the
  /// ordinary pin while it is up keeps the entry until it hides. On macOS the
  /// policy cannot change under an app that is in front, and an entry for a
  /// window still showing is no harm anyway.
  ///
  /// macOS goes through AppPresence (MainFlutterWindow.swift), which hands
  /// focus back before dropping to an agent app; Windows uses window_manager's
  /// setSkipTaskbar, the taskbar button. The state is cached only once the
  /// platform has taken it, so a failure is retried on the next change.
  Future<void> _applyAppPresence() async {
    final wanted = _pinned && !_onTop && _showingSpotlight;
    if (wanted == _inAppSwitcher) return;
    if (!wanted && _showingSpotlight) return;
    try {
      if (Platform.isMacOS) {
        await _appPresence.invokeMethod<void>(
          wanted ? 'enterAppSwitcher' : 'leaveAppSwitcher',
        );
      } else {
        await windowManager.setSkipTaskbar(!wanted);
      }
      _inAppSwitcher = wanted;
    } on Exception catch (e) {
      debugPrint('[WindowService] Could not change app switcher presence: $e');
    }
  }

  static const MethodChannel _appPresence = MethodChannel(
    'com.ghostcopy/app_presence',
  );

  /// Where a pinned Spotlight was when it last left the screen or grew for a
  /// dialog, so it comes back there rather than recentred. Null while
  /// unpinned.
  Offset? _pinnedPosition;

  /// The window is up with the Spotlight's geometry, not the tray menu's.
  bool get _showingSpotlight => _isVisible && !_framelessForTrayMenu;

  @override
  Future<void> setFramelessForTrayMenu() async {
    // The menu is about to move this window to the corner; remember where a
    // pinned Spotlight was first. Hidden and resized by now, not yet moved.
    await _rememberPinnedPosition();
    _framelessForTrayMenu = true;
    await _applyAppPresence();
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
    await _applyTopmost();
  }

  @override
  Future<void> showSpotlight() async {
    if (!_isDesktop()) {
      return;
    }

    // A pinned window already on screen only needs bringing forward. The
    // rest of this hides, resizes and recentres it: a blink, and the place
    // it was dragged to lost. Asked of the platform too, because the tray
    // menu hides the window without going through hideSpotlight.
    if (_pinned && _showingSpotlight && await windowManager.isVisible()) {
      await windowManager.focus();
      return;
    }

    // Started now, needed after the resize: it depends on none of what
    // comes between, and enumerating displays is not quick.
    final pinnedPosition = _onScreen(_pinnedPosition);

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
      // The menu needed to be topmost; an unpinned Spotlight does not, and
      // leaving it set would pin the whole app over everything else for the
      // rest of the session. Same gate, same reason: this is where the tray
      // menu's window changes are undone.
      await _applyTopmost();
    }

    // Set to Spotlight size and position (do this while hidden). A pinned
    // window goes back where it was, if that is still on a display.
    await windowManager.setSize(const Size(_windowWidth, _windowHeight));
    await _place(pinnedPosition);

    // Show and focus
    await windowManager.show();
    await windowManager.focus();
    _isVisible = true;
    await _applyAppPresence();
    debugPrint('[WindowService] Spotlight shown');
  }

  @override
  Future<void> setPinned({required bool pinned, required bool onTop}) async {
    _pinned = pinned;
    _onTop = pinned && onTop;
    if (!pinned) _pinnedPosition = null;
    if (!_isDesktop()) return;
    await _applyTopmost();
    await _applyAppPresence();
  }

  @override
  Future<void> hideSpotlight() async {
    if (!_isDesktop()) return;

    _hideStartedAt = DateTime.now();
    // Together: a hidden window keeps its position, and the hide should not
    // wait on reading it.
    await Future.wait([windowManager.hide(), _rememberPinnedPosition()]);
    debugPrint('[WindowService] Hiding spotlight window');
    _isVisible = false;
    await _applyAppPresence();

    // Enter Tray Mode AFTER hiding window to pause UI animations
    // Note: Only pauses UI-related resources (AnimationControllers, etc.)
    // Core services continue running: Realtime stream, hotkeys, tray
    _lifecycleController?.enterTrayMode();
  }

  /// Note where a pinned Spotlight is, while it still has the Spotlight's
  /// geometry. Checked before the first await, so callers can start it
  /// alongside whatever takes the window off screen.
  Future<void> _rememberPinnedPosition() async {
    if (!_pinned || !_showingSpotlight) return;
    try {
      _pinnedPosition = await windowManager.getPosition();
    } on Exception catch (e) {
      debugPrint('[WindowService] Could not read the window position: $e');
    }
  }

  /// Put the Spotlight where a pin left it, or in the centre when there is
  /// no such place or it is no longer on a display.
  Future<void> _place(Future<Offset?> pinnedPosition) async {
    final position = await pinnedPosition;
    if (position != null) {
      await windowManager.setPosition(position);
    } else {
      await windowManager.center();
    }
  }

  /// [position], if a Spotlight placed there would still be on a display -
  /// one may have been unplugged since. Null otherwise.
  Future<Offset?> _onScreen(Offset? position) async {
    if (position == null) return null;
    try {
      final displays = await screenRetriever.getAllDisplays();
      final centre =
          position + const Offset(_windowWidth / 2, _windowHeight / 2);
      return displayContaining(displays, centre) == null ? null : position;
    } on Exception catch (e) {
      debugPrint('[WindowService] Could not read displays: $e');
      return null;
    }
  }

  @override
  Future<void> centerWindow() async {
    if (!_isDesktop()) return;
    await windowManager.center();
  }

  @override
  Future<void> growToHeight(double height) async {
    if (!_isDesktop()) return;
    // Centred to make room, so a pinned window notes its place first and
    // restoreSpotlightSize puts it back there.
    await _rememberPinnedPosition();
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
    await _place(_onScreen(_pinnedPosition));
  }

  @override
  Future<void> startDragging() async {
    if (!_isDesktop()) return;
    await windowManager.startDragging();
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
