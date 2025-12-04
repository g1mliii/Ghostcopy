/// Abstract interface for window management operations
abstract class IWindowService {
  /// Initialize the window service
  Future<void> initialize();
  
  /// Show the Spotlight window
  Future<void> showSpotlight();
  
  /// Hide the Spotlight window
  Future<void> hideSpotlight();
  
  /// Center the window on the screen
  Future<void> centerWindow();
  
  /// Focus the window
  Future<void> focusWindow();
  
  /// Check if the window is currently visible
  bool get isVisible;
}
