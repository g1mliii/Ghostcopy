import '../lifecycle_controller.dart';

/// Implementation of LifecycleController for Sleep Mode management
///
/// Manages UI-only pausable resources to save CPU when window is hidden.
///
/// WHAT TO REGISTER AS PAUSABLE:
/// ✅ AnimationControllers (fade effects, loading spinners, etc.)
/// ✅ UI-only streams (search filters, UI state streams)
/// ✅ TickerProviders that drive visual animations
///
/// WHAT NOT TO REGISTER (must run 24/7):
/// ❌ Realtime clipboard sync stream (core feature - must receive clips)
/// ❌ Hotkey listener (needed to wake the app from tray)
/// ❌ System tray service (user needs access)
/// ❌ Supabase Auth session (must maintain authentication)
///
/// Sleep Mode is for UI optimizations ONLY, not core app functionality.
class LifecycleController implements ILifecycleController {
  final Set<Pausable> _pausables = {};
  bool _isSleeping = false;

  @override
  bool get isSleeping => _isSleeping;

  @override
  void enterSleepMode() {
    if (_isSleeping) return;

    _isSleeping = true;

    // Pause all registered resources
    for (final pausable in _pausables) {
      try {
        pausable.pause();
      } on Exception catch (e) {
        // Log but continue pausing other resources
        // ignore: avoid_print
        print('Failed to pause resource: $e');
      }
    }
  }

  @override
  void exitSleepMode() {
    if (!_isSleeping) return;

    _isSleeping = false;

    // Resume all registered resources
    for (final pausable in _pausables) {
      try {
        pausable.resume();
      } on Exception catch (e) {
        // Log but continue resuming other resources
        // ignore: avoid_print
        print('Failed to resume resource: $e');
      }
    }
  }

  @override
  void addPausable(Pausable pausable) {
    _pausables.add(pausable);

    // If already sleeping, pause the newly added resource immediately
    if (_isSleeping) {
      try {
        pausable.pause();
      } on Exception catch (e) {
        // ignore: avoid_print
        print('Failed to pause newly added resource: $e');
      }
    }
  }

  @override
  void removePausable(Pausable pausable) {
    _pausables.remove(pausable);
  }

  /// Dispose and cleanup all resources
  @override
  void dispose() {
    _pausables.clear();
    _isSleeping = false;
  }
}
