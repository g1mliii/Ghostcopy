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

  /// Return the window to the standard Spotlight size, and a pinned one to
  /// where it was before [growToHeight] centred it.
  Future<void> restoreSpotlightSize();

  /// Focus the window
  Future<void> focusWindow();

  /// Keep the Spotlight open while [pinned], rather than hidden on blur.
  ///
  /// Pinned, [showSpotlight] also leaves the window where it is: one already
  /// on screen is only focused, and one coming back from a hide returns to
  /// where it was rather than the centre.
  ///
  /// [onTop] also keeps it above every other window; without it a pinned
  /// window is an ordinary one that other apps can cover.
  Future<void> setPinned({required bool pinned, required bool onTop});

  /// Move the window with the pointer, from a press on a drag area. The
  /// Spotlight is borderless, so it has no title bar to do this.
  Future<void> startDragging();

  /// Check if the window is currently visible
  bool get isVisible;

  /// Whether [hideSpotlight] began within the last [window].
  ///
  /// For input that arrives just after the window lost focus: clicking the
  /// tray icon deactivates an open Spotlight, whose blur hides it before the
  /// click itself is handled. The click then finds the window hidden when the
  /// user was closing it.
  bool hiddenWithin(Duration window);

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}
