/// Interface for resources that can be paused and resumed
abstract class Pausable {
  /// Pause the resource
  void pause();
  
  /// Resume the resource
  void resume();
}

/// Abstract interface for lifecycle management and Sleep Mode
abstract class ILifecycleController {
  /// Check if the app is currently in Sleep Mode
  bool get isSleeping;
  
  /// Enter Sleep Mode (pause all resources)
  void enterSleepMode();
  
  /// Exit Sleep Mode (resume all resources)
  void exitSleepMode();
  
  /// Add a pausable resource to be managed
  void addPausable(Pausable pausable);
  
  /// Remove a pausable resource from management
  void removePausable(Pausable pausable);
}
