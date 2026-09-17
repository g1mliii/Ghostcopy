import 'dart:ui';

/// Represents a menu item in the system tray
class TrayMenuItem {
  const TrayMenuItem({
    required this.label,
    this.onTap,
    this.isSeparator = false,
    this.isChecked,
  });

  /// Create a separator menu item
  const TrayMenuItem.separator()
    : label = '',
      onTap = null,
      isSeparator = true,
      isChecked = null;

  final String label;
  final VoidCallback? onTap;
  final bool isSeparator;

  /// Null for a plain item. Set it - to either value - to make the item
  /// checkable, so an unchecked toggle stays distinguishable from an item
  /// that has no state at all.
  final bool? isChecked;
}

/// Abstract interface for system tray management
abstract class ITrayService {
  /// Initialize the tray service
  Future<void> initialize();

  /// Set the tray icon
  Future<void> setIcon(String iconPath);

  /// Set the context menu items
  Future<void> setContextMenu(List<TrayMenuItem> items);

  /// Screen bounds of the tray icon, in the same top-left-origin coordinate
  /// space `window_manager` uses for window positions. Null when the platform
  /// cannot report them.
  Future<Rect?> getIconBounds();

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}
