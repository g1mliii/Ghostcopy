import 'dart:io';
import 'package:system_tray/system_tray.dart';
import '../tray_service.dart';

/// Concrete implementation of ITrayService using system_tray package
///
/// Manages the system tray icon and context menu for desktop platforms.
/// Uses custom window for menu to match app styling.
class TrayService implements ITrayService {
  final SystemTray _systemTray = SystemTray();

  // Callback for when tray icon is right-clicked
  void Function()? onRightClick;

  @override
  Future<void> initialize() async {
    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    await _systemTray.initSystemTray(
      title: 'GhostCopy',
      iconPath: _getTrayIconPath(),
    );

    // Register right-click handler to show custom menu
    _systemTray.registerSystemTrayEventHandler((eventName) {
      if (eventName == kSystemTrayEventClick) {
        // Left click - could show spotlight
      } else if (eventName == kSystemTrayEventRightClick) {
        // Right click - trigger custom menu
        onRightClick?.call();
      }
    });
  }

  @override
  Future<void> setIcon(String iconPath) async {
    if (!_isDesktop()) return;
    await _systemTray.setImage(iconPath);
  }

  @override
  Future<void> setContextMenu(List<TrayMenuItem> items) async {
    // No-op - we use custom window for menu
  }

  @override
  Future<void> dispose() async {
    if (!_isDesktop()) return;

    // Clean up callback to prevent memory leak
    onRightClick = null;

    await _systemTray.destroy();
  }

  /// Get platform-specific tray icon path
  String _getTrayIconPath() {
    if (Platform.isWindows) {
      return 'assets/icons/tray_icon.ico';
    } else if (Platform.isMacOS) {
      return 'assets/icons/tray_icon.png';
    } else if (Platform.isLinux) {
      return 'assets/icons/tray_icon.png';
    }
    return '';
  }

  /// Check if running on desktop platform
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
