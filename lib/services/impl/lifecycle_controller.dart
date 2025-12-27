import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/clipboard_item.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/settings_service.dart';
import '../lifecycle_controller.dart';

/// Enhanced implementation of LifecycleController
///
/// Manages three types of app states:
/// 1. Tray Mode (UI) - Window visibility for UI resource optimization
/// 2. Connection Mode (Network) - Realtime/Polling/Paused for Supabase
/// 3. Power State (System) - Sleep/Wake/Lock detection
///
/// Single source of truth for all app lifecycle management.
class LifecycleController implements ILifecycleController {
  LifecycleController({
    required IClipboardSyncService clipboardSyncService,
    required ISettingsService settingsService,
  })  : _clipboardSyncService = clipboardSyncService,
        _settingsService = settingsService;

  final IClipboardSyncService _clipboardSyncService;
  final ISettingsService _settingsService;

  // ========== TRAY MODE (UI State) ==========

  final Set<Pausable> _pausables = {};
  bool _isInTrayMode = false;

  @override
  bool get isInTrayMode => _isInTrayMode;

  // ========== CONNECTION MODE (Network State) ==========

  ConnectionMode _connectionMode = ConnectionMode.realtime;
  final _connectionModeController = StreamController<ConnectionMode>.broadcast();

  @override
  ConnectionMode get connectionMode => _connectionMode;

  @override
  Stream<ConnectionMode> get connectionModeStream =>
      _connectionModeController.stream;

  // ========== POWER STATE (System State) ==========

  PowerState _powerState = PowerState.awake;

  @override
  PowerState get powerState => _powerState;

  // ========== INACTIVITY TRACKING ==========

  DateTime? _lastClipboardActivity;
  Timer? _inactivityCheckTimer;
  static const Duration _realtimeIdleThreshold = Duration(minutes: 15);

  // ========== FEATURE FLAG ==========

  bool _isHybridModeEnabled = false;

  // ========== CALLBACK RESTORATION ==========

  // Store original callbacks so we can restore them on dispose
  void Function(ClipboardItem)? _originalOnClipboardSent;
  void Function()? _originalOnClipboardReceived;

  // ========== INITIALIZATION ==========

  @override
  Future<void> initialize() async {
    debugPrint('[Lifecycle] 🚀 Initializing lifecycle controller...');

    // 1. Check feature flag from Supabase
    _isHybridModeEnabled = await _settingsService.isHybridModeEnabled();

    if (!_isHybridModeEnabled) {
      debugPrint('[Lifecycle] 🟢 Hybrid mode DISABLED - pure realtime');
      return; // Stay in realtime mode always
    }

    debugPrint('[Lifecycle] 🟡 Hybrid mode ENABLED - smart switching active');

    // 2. Start inactivity monitoring
    _startInactivityMonitoring();

    // 3. Wire up clipboard activity callbacks (store originals for restoration)
    _originalOnClipboardSent = _clipboardSyncService.onClipboardSent;
    _originalOnClipboardReceived = _clipboardSyncService.onClipboardReceived;

    _clipboardSyncService.onClipboardSent = (item) {
      notifyClipboardActivity();
      _originalOnClipboardSent?.call(item);
    };

    _clipboardSyncService.onClipboardReceived = () {
      notifyClipboardActivity();
      _originalOnClipboardReceived?.call();
    };

    debugPrint('[Lifecycle] ✅ Lifecycle controller initialized');
  }

  // ========== TRAY MODE (UI) - Renamed from Sleep Mode ==========

  @override
  void enterTrayMode() {
    if (_isInTrayMode) return;

    debugPrint('[Lifecycle] 📦 Entering TRAY MODE (window hidden)');
    _isInTrayMode = true;

    // Pause all registered UI resources (AnimationControllers, etc.)
    for (final pausable in _pausables) {
      try {
        pausable.pause();
      } on Exception catch (e) {
        debugPrint('[Lifecycle] ⚠️  Failed to pause resource: $e');
      }
    }
  }

  @override
  void exitTrayMode() {
    if (!_isInTrayMode) return;

    debugPrint('[Lifecycle] 📭 Exiting TRAY MODE (window shown)');
    _isInTrayMode = false;

    // Resume all registered UI resources
    for (final pausable in _pausables) {
      try {
        pausable.resume();
      } on Exception catch (e) {
        debugPrint('[Lifecycle] ⚠️  Failed to resume resource: $e');
      }
    }

    // When spotlight opens, switch back to realtime if in polling mode
    if (_connectionMode == ConnectionMode.polling) {
      debugPrint('[Lifecycle] 🪟 Spotlight opened → Switching to REALTIME');
      switchToRealtime();
    }
  }

  @override
  void addPausable(Pausable pausable) {
    _pausables.add(pausable);

    // If already in tray mode, pause the newly added resource immediately
    if (_isInTrayMode) {
      try {
        pausable.pause();
      } on Exception catch (e) {
        debugPrint('[Lifecycle] ⚠️  Failed to pause newly added resource: $e');
      }
    }
  }

  @override
  void removePausable(Pausable pausable) {
    _pausables.remove(pausable);
  }

  // ========== CONNECTION MODE (Network) ==========

  void _startInactivityMonitoring() {
    // Check every 2 minutes if we should switch to polling
    _inactivityCheckTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _checkInactivity(),
    );
    debugPrint('[Lifecycle] ⏰ Inactivity monitoring started (check every 2 min)');
  }

  void _checkInactivity() {
    if (!_isHybridModeEnabled) return;
    if (_connectionMode != ConnectionMode.realtime) return;
    if (_powerState != PowerState.awake) {
      return; // Don't check during sleep/lock
    }

    final now = DateTime.now();
    final isWindowHidden = _isInTrayMode;

    // Calculate idle time
    final idleDuration = _lastClipboardActivity != null
        ? now.difference(_lastClipboardActivity!)
        : Duration.zero;

    // Switch to polling if BOTH conditions true:
    // - Window is hidden (in tray) AND
    // - No clipboard activity for 15 minutes
    if (isWindowHidden && idleDuration >= _realtimeIdleThreshold) {
      debugPrint(
        '[Lifecycle] ⏱️  Idle ${idleDuration.inMinutes} min in tray → POLLING',
      );
      switchToPolling();
    }
  }

  @override
  void switchToRealtime() {
    if (_connectionMode == ConnectionMode.realtime) return;
    if (_powerState != PowerState.awake) {
      return; // Can't switch during sleep/lock
    }

    debugPrint('[Lifecycle] 🔵 Switching to REALTIME mode');
    _connectionMode = ConnectionMode.realtime;
    _connectionModeController.add(_connectionMode);

    // Stop polling, start realtime
    _clipboardSyncService
      ..stopPolling()
      ..resumeRealtime();
  }

  @override
  void switchToPolling() {
    if (_connectionMode == ConnectionMode.polling) return;
    if (_powerState != PowerState.awake) {
      return; // Can't switch during sleep/lock
    }

    debugPrint('[Lifecycle] 🟡 Switching to POLLING mode (5 min interval)');
    _connectionMode = ConnectionMode.polling;
    _connectionModeController.add(_connectionMode);

    // Stop realtime, start polling
    _clipboardSyncService
      ..pauseRealtime()
      ..startPolling(interval: const Duration(minutes: 5));
  }

  @override
  void notifyClipboardActivity() {
    _lastClipboardActivity = DateTime.now();

    // If in polling mode and user becomes active, switch back to realtime
    if (_connectionMode == ConnectionMode.polling && _isHybridModeEnabled) {
      debugPrint('[Lifecycle] 📋 Clipboard activity → Switching to REALTIME');
      switchToRealtime();
    }
  }

  // ========== POWER STATE (System sleep/lock) ==========

  @override
  void onSystemSleep() {
    if (_powerState == PowerState.systemSleeping) return;

    debugPrint('[Lifecycle] 💤 System SLEEP detected → Pausing EVERYTHING');
    _powerState = PowerState.systemSleeping;

    // Pause all network activity
    _pauseConnections();
  }

  @override
  void onSystemWake() {
    if (_powerState == PowerState.awake) return;

    debugPrint('[Lifecycle] ⏰ System WAKE detected → Resuming');
    _powerState = PowerState.awake;

    // Resume to realtime (user just woke system, probably active)
    _resumeConnections();
  }

  @override
  void onScreenLock() {
    if (_powerState == PowerState.screenLocked) return;

    debugPrint('[Lifecycle] 🔒 Screen LOCKED → Pausing connections');
    _powerState = PowerState.screenLocked;

    // Pause network activity
    _pauseConnections();
  }

  @override
  void onScreenUnlock() {
    if (_powerState == PowerState.awake) return;

    debugPrint('[Lifecycle] 🔓 Screen UNLOCKED → Resuming');
    _powerState = PowerState.awake;

    // Resume connections
    _resumeConnections();
  }

  void _pauseConnections() {
    debugPrint('[Lifecycle] ⏸️  Pausing all connections');

    // Save current mode to restore later
    _connectionMode = ConnectionMode.paused;
    _connectionModeController.add(_connectionMode);

    // Stop everything
    _clipboardSyncService
      ..pauseRealtime()
      ..stopPolling()
      ..stopClipboardMonitoring();
  }

  void _resumeConnections() {
    debugPrint('[Lifecycle] ▶️  Resuming connections');

    // Always resume to realtime (user just woke system/unlocked screen)
    switchToRealtime();

    // Resume clipboard monitoring if it was stopped
    final wasMonitoring = _clipboardSyncService.isMonitoring;
    if (!wasMonitoring) {
      _clipboardSyncService.startClipboardMonitoring();
    }
  }

  // ========== CLEANUP & DISPOSAL ==========

  @override
  void dispose() {
    debugPrint('[Lifecycle] 🗑️  Disposing all resources');

    // Restore original callbacks to prevent memory leaks
    if (_isHybridModeEnabled) {
      _clipboardSyncService.onClipboardSent = _originalOnClipboardSent;
      _clipboardSyncService.onClipboardReceived = _originalOnClipboardReceived;
      _originalOnClipboardSent = null;
      _originalOnClipboardReceived = null;
    }

    // Cancel timers
    _inactivityCheckTimer?.cancel();
    _inactivityCheckTimer = null;

    // Close streams
    _connectionModeController.close();

    // Clear pausables
    _pausables.clear();

    // Reset state
    _isInTrayMode = false;
    _connectionMode = ConnectionMode.realtime;
    _powerState = PowerState.awake;

    debugPrint('[Lifecycle] ✅ Disposed successfully');
  }
}
