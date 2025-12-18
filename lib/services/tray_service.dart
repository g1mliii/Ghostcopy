import 'package:flutter/foundation.dart';

/// Represents a menu item in the system tray
class TrayMenuItem {
  const TrayMenuItem({
    required this.label,
    this.onTap,
    this.isSeparator = false,
    this.isChecked = false,
  });

  /// Create a separator menu item
  const TrayMenuItem.separator()
    : label = '',
      onTap = null,
      isSeparator = true,
      isChecked = false;

  final String label;
  final VoidCallback? onTap;
  final bool isSeparator;
  final bool isChecked;
}

/// Abstract interface for system tray management
abstract class ITrayService {
  /// Initialize the tray service
  Future<void> initialize();

  /// Set the tray icon
  Future<void> setIcon(String iconPath);

  /// Set the context menu items
  Future<void> setContextMenu(List<TrayMenuItem> items);

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}
