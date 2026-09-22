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

  /// Mark a pending update on the tray itself, without opening a window or
  /// taking focus.
  ///
  /// On the interface rather than the macOS implementation alone. Reaching it
  /// through a cast out of ITrayService threw for any injected fake, which is
  /// the one thing the interface exists to allow, and the implementation
  /// already no-ops where there is no native menu - so there is nothing
  /// platform-specific for a caller to know.
  Future<void> setUpdateAvailable({required bool available});

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}
