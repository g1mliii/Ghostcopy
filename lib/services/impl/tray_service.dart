import 'dart:async';
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

  /// macOS gets a real NSMenu so the menu matches every other menu bar app -
  /// vibrancy, keyboard navigation and positioning all come from AppKit. The
  /// Windows tray menu is still the custom Flutter window, because the native
  /// one there does not match the app at all.
  bool get _usesNativeMenu => Platform.isMacOS;

  @override
  Future<void> initialize() async {
    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    // Add listener for tray events
    trayManager.addListener(this);

    await trayManager.setIcon(_getTrayIconPath(), isTemplate: Platform.isMacOS);

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
    // Windows drives the custom Flutter window from the click event instead.
    if (!_usesNativeMenu) return;

    await trayManager.setContextMenu(
      Menu(
        items: items.map((item) {
          if (item.isSeparator) return MenuItem.separator();

          final checked = item.isChecked;
          if (checked != null) {
            // Only a 'checkbox' item gets an NSMenuItem state, which is how a
            // Mac menu shows an on/off toggle.
            return MenuItem.checkbox(
              label: item.label,
              checked: checked,
              onClick: (_) => item.onTap?.call(),
            );
          }

          return MenuItem(
            label: item.label,
            onClick: (_) => item.onTap?.call(),
          );
        }).toList(),
      ),
    );
  }

  /// Mark a pending macOS update without opening a window or taking focus.
  @override
  Future<void> setUpdateAvailable({required bool available}) async {
    if (!_usesNativeMenu) return;
    await trayManager.setTitle(available ? '•' : '');
    await trayManager.setToolTip(
      available ? 'GhostCopy — Update available' : 'GhostCopy',
    );
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
    // macOS status items open their menu on either button, so left-click is
    // routed to the same handler there rather than left dead.
    //
    // Guarded rather than unconditional: on Windows this used to do nothing,
    // and routing it through _openMenu made a left-click hide the main window
    // and repurpose it as the menu - a behaviour change to Windows that only
    // macOS reasoning asked for.
    if (_usesNativeMenu) _openMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    _openMenu();
  }

  void _openMenu() {
    if (_usesNativeMenu) {
      // AppKit owns placement, appearance and dismissal from here.
      unawaited(trayManager.popUpContextMenu());
    } else {
      onRightClick?.call();
    }
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
