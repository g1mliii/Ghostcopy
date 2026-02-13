import 'package:flutter/animation.dart';

/// Connection modes for Supabase realtime management
enum ConnectionMode {
  /// Active WebSocket connection for realtime updates
  realtime,

  /// Periodic HTTP polling (used after 15 min inactivity in tray)
  polling,

  /// All connections paused (system sleep or screen lock)
  paused,
}

/// System power states for lifecycle management
enum PowerState {
  /// Normal operation - system is awake and unlocked
  awake,

  /// Computer is sleeping or hibernating
  systemSleeping,

  /// Screen is locked but system is awake
  screenLocked,
}

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

/// Abstract interface for lifecycle management and Tray Mode
///
/// Tray Mode pauses UI-only resources when Spotlight window is hidden.
/// Connection Mode manages Supabase realtime/polling states.
/// Power State handles system sleep and screen lock detection.
abstract class ILifecycleController {
  // ========== TRAY MODE (UI State) ==========

  /// Check if the app is currently in Tray Mode (window hidden)
  bool get isInTrayMode;

  /// Enter Tray Mode (pause UI animations and non-essential streams)
  void enterTrayMode();

  /// Exit Tray Mode (resume UI animations)
  void exitTrayMode();

  /// Add a UI resource to be paused/resumed with Tray Mode
  /// Returns true if added, false if rejected (at capacity limit)
  bool addPausable(Pausable pausable);

  /// Remove a UI resource from Tray Mode management
  void removePausable(Pausable pausable);

  // ========== CONNECTION MODE (Network State) ==========

  /// Current connection mode (realtime/polling/paused)
  ConnectionMode get connectionMode;

  /// Stream of connection mode changes
  Stream<ConnectionMode> get connectionModeStream;

  /// Switch to realtime mode (WebSocket)
  void switchToRealtime();

  /// Switch to polling mode (HTTP every 5 min)
  void switchToPolling();

  // ========== POWER STATE (System State) ==========

  /// Current system power state
  PowerState get powerState;

  /// Handle system sleep event
  void onSystemSleep();

  /// Handle system wake event
  void onSystemWake();

  /// Handle screen lock event
  void onScreenLock();

  /// Handle screen unlock event
  void onScreenUnlock();

  // ========== ACTIVITY TRACKING ==========

  /// Notify controller of clipboard activity (resets inactivity timer)
  void notifyClipboardActivity();

  // ========== INITIALIZATION & CLEANUP ==========

  /// Initialize the lifecycle controller (load feature flags, start monitoring)
  Future<void> initialize();

  /// Dispose and cleanup all resources
  void dispose();
}
