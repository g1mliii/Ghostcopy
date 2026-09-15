import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import '../tray_service.dart';

/// Concrete implementation of ITrayService using tray_manager package
///
/// Manages the system tray icon and context menu for desktop platforms.
/// Uses custom window for menu to match app styling.
class TrayService with TrayListener implements ITrayService {
  // Callback for when tray icon is right-clicked
  void Function()? onRightClick;

  @override
  Future<void> initialize() async {
    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    // Add listener for tray events
    trayManager.addListener(this);

    await trayManager.setIcon(
      _getTrayIconPath(),
      isTemplate: Platform.isMacOS,
    );

    // On macOS, the title is usually not shown in tray for icon-only apps,
    // but we can set it if needed. Leaving empty for now for icon-only feel.
  }

  @override
  Future<void> setIcon(String iconPath) async {
    if (!_isDesktop()) return;
    await trayManager.setIcon(iconPath, isTemplate: Platform.isMacOS);
  }

  @override
  Future<void> setContextMenu(List<TrayMenuItem> items) async {
    // No-op - we use custom window for menu, handled via event
  }

  @override
  Future<void> dispose() async {
    if (!_isDesktop()) return;

    // Clean up callback to prevent memory leak
    onRightClick = null;

    // Remove listener
    trayManager.removeListener(this);

    // There isn't a strict 'destroy' method for trayManager exposed usually,
    // but removing the listener helps.
  }

  // --- TrayListener overrides ---

  @override
  void onTrayIconMouseDown() {
    // Left click - could show spotlight or toggle window if needed
  }

  @override
  void onTrayIconRightMouseDown() {
    // Right click - trigger custom menu
    onRightClick?.call();

    // Also support native menu popping up if we set one,
    // but here we are using custom window callback.
  }

  @override
  void onTrayIconRightMouseUp() {
    // Some platforms might trigger on up or down, handling down usually suffices for menus
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    // Handle native menu item clicks if used
  }

  /// Get platform-specific tray icon path
  ///
  /// Each platform wants a different asset, so they are no longer shared:
  /// - Windows: .ico containing 16/32/48px frames, picked per DPI.
  /// - macOS: a black-on-transparent TEMPLATE image at 44px (the @2x of the
  ///   22pt menu bar slot). The menu bar tints it automatically, which is what
  ///   makes it invert correctly in dark mode and when the bar is highlighted.
  ///   A full-colour icon cannot do that. The tinting only happens when
  ///   `isTemplate` is passed to setIcon, so the two go together.
  /// - Linux: 24px, the size most panels expect.
  String _getTrayIconPath() {
    if (Platform.isWindows) {
      return 'assets/icons/tray_icon.ico';
    } else if (Platform.isMacOS) {
      return 'assets/icons/tray_icon_macos.png';
    } else if (Platform.isLinux) {
      return 'assets/icons/tray_icon_linux.png';
    }
    return '';
  }

  /// Check if running on desktop platform
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
