import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import '../tray_service.dart';

/// Concrete implementation of ITrayService using tray_manager package
///
/// Manages the system tray icon and context menu for desktop platforms.
/// Uses custom window for menu to match app styling.
class TrayService with TrayListener implements ITrayService {
  // Callback for when tray icon is right-clicked
  void Function()? onRightClick;

  /// Windows only: what a left-click on the tray icon does.
  ///
  /// macOS routes left-click to the menu instead, because that is what a
  /// status item does there - see [onTrayIconMouseDown].
  void Function()? onLeftClick;

  /// macOS gets a real NSMenu so the menu matches every other menu bar app -
  /// vibrancy, keyboard navigation and positioning all come from AppKit. The
  /// Windows tray menu is still the custom Flutter window, because the native
  /// one there does not match the app at all.
  /// Linux AppIndicator exposes its menu through the desktop shell; it does
  /// not emit the mouse events used by our custom Windows tray window.
  bool get _usesNativeMenu => Platform.isMacOS || Platform.isLinux;

  @override
  Future<void> initialize() async {
    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    // Add listener for tray events
    trayManager.addListener(this);

    await trayManager.setIcon(_getTrayIconPath(), isTemplate: Platform.isMacOS);

    // Without this, hovering the Windows tray icon shows an empty tooltip box
    // instead of the app name. tray_manager has no tooltip on Linux.
    if (!Platform.isLinux) {
      await trayManager.setToolTip('GhostCopy');
    }

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
    if (!Platform.isMacOS) return;
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
    onLeftClick = null;

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
    // Guarded rather than unconditional: routing Windows through _openMenu
    // made a left-click hide the main window and repurpose it as the menu - a
    // behaviour change that only macOS reasoning asked for.
    //
    // Windows gets the convention its users expect instead: left-click opens
    // the app, right-click opens the menu, the way Discord, Steam and Dropbox
    // behave. Doing nothing at all, which is what it did before, reads as a
    // broken icon.
    if (_usesNativeMenu) {
      _openMenu();
    } else {
      onLeftClick?.call();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    _openMenu();
  }

  void _openMenu() {
    // AppIndicator opens the installed menu itself. popUpContextMenu is not
    // implemented by the Linux plugin.
    if (Platform.isLinux) return;
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
  /// - Linux: a bare monochrome ghost, matching Plasma's own tray icons.
  ///   AppIndicator hands Plasma a file path, which it never recolours, so the
  ///   ink is picked here from the panel's colour scheme - see
  ///   [linuxTrayIconFor].
  String _getTrayIconPath() {
    if (Platform.isWindows) {
      return 'assets/icons/tray_icon.ico';
    } else if (Platform.isMacOS) {
      return 'assets/icons/tray_icon_macos.png';
    } else if (Platform.isLinux) {
      return linuxTrayIconFor(_readKdeGlobals());
    }
    return '';
  }

  static String? _readKdeGlobals() {
    final configHome =
        Platform.environment['XDG_CONFIG_HOME'] ??
        '${Platform.environment['HOME']}/.config';
    try {
      return File('$configHome/kdeglobals').readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// White ghost for a dark panel, dark ghost for a light one.
  ///
  /// Plasma's panel takes its background from the colour scheme's
  /// `[Colors:Window]` group in kdeglobals. Without one - no KDE, or a scheme
  /// that does not set it - white is the default, since Breeze Dark is what
  /// CachyOS ships. Read once at startup, so a scheme change shows on the next
  /// launch.
  @visibleForTesting
  static String linuxTrayIconFor(String? kdeglobals) {
    const white = 'assets/icons/tray_icon_linux.png';
    const dark = 'assets/icons/tray_icon_linux_light_panel.png';
    if (kdeglobals == null) return white;

    var inWindowGroup = false;
    for (final raw in kdeglobals.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inWindowGroup = line == '[Colors:Window]';
        continue;
      }
      if (!inWindowGroup || !line.startsWith('BackgroundNormal=')) continue;

      final rgb = line
          .substring('BackgroundNormal='.length)
          .split(',')
          .map((part) => int.tryParse(part.trim()))
          .toList();
      if (rgb.length < 3 || rgb.take(3).any((c) => c == null)) return white;
      // Rec. 709 luma: a light panel is one the eye reads as light.
      final luma = 0.2126 * rgb[0]! + 0.7152 * rgb[1]! + 0.0722 * rgb[2]!;
      return luma > 127.5 ? dark : white;
    }
    return white;
  }

  /// Check if running on desktop platform
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
