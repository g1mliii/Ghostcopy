import 'package:flutter/animation.dart';

/// Interface for UI resources that can be paused when window is hidden
///
/// Implement this for:
/// - AnimationControllers
/// - UI-only stream subscriptions
/// - TickerProviders
///
/// DO NOT implement for core services that must run 24/7:
/// - Realtime clipboard sync
/// - Hotkey listeners
/// - System tray
abstract class Pausable {
  /// Pause the resource (stop animations, cancel UI streams, etc.)
  void pause();

  /// Resume the resource (restart animations, resubscribe to UI streams)
  void resume();
}

/// Wrapper for AnimationController that implements Pausable interface
///
/// This allows AnimationControllers to be registered with LifecycleController
/// for automatic pausing/resuming during Sleep Mode.
class PausableAnimationController implements Pausable {
  PausableAnimationController(this.controller);

  final AnimationController controller;

  @override
  void pause() {
    controller.stop();
  }

  @override
  void resume() {
    // Only resume if the controller is currently animating
    // Don't start new animations automatically
    if (controller.isAnimating) {
      controller.forward();
    }
  }
}

/// Abstract interface for lifecycle management and Sleep Mode
///
/// Sleep Mode pauses UI-only resources when Spotlight window is hidden.
/// Core services (Realtime sync, hotkeys) continue running 24/7.
abstract class ILifecycleController {
  /// Check if the app is currently in Sleep Mode
  bool get isSleeping;

  /// Enter Sleep Mode (pause UI animations and non-essential streams)
  void enterSleepMode();

  /// Exit Sleep Mode (resume UI animations)
  void exitSleepMode();

  /// Add a UI resource to be paused/resumed with Sleep Mode
  void addPausable(Pausable pausable);

  /// Remove a UI resource from Sleep Mode management
  void removePausable(Pausable pausable);

  /// Dispose and cleanup all resources
  void dispose();
}
