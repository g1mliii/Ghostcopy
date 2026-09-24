/// Abstract interface for window management operations
abstract class IWindowService {
  /// Initialize the window service
  Future<void> initialize();

  /// Show the Spotlight window
  Future<void> showSpotlight();

  /// Hide the Spotlight window
  Future<void> hideSpotlight();

  /// Make the window frameless for the Windows tray menu. [showSpotlight]
  /// restores the Spotlight's frame the next time it runs, and only then.
  Future<void> setFramelessForTrayMenu();

  /// Center the window on the screen
  Future<void> centerWindow();

  /// Grow the window to [height] for content that does not fit the Spotlight
  /// window, such as the link-device QR code. Call [restoreSpotlightSize] when
  /// that content closes.
  Future<void> growToHeight(double height);

  /// Return the window to the standard Spotlight size.
  Future<void> restoreSpotlightSize();

  /// Focus the window
  Future<void> focusWindow();

  /// Check if the window is currently visible
  bool get isVisible;

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}
