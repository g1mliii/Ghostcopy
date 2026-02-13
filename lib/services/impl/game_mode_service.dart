import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/clipboard_item.dart';
import '../game_mode_service.dart';

/// Concrete implementation of IGameModeService
///
/// Game Mode suppresses notifications during fullscreen apps/games.
/// Notifications are queued and displayed when Game Mode is deactivated.
///
/// Performance optimizations:
/// - Stream-based reactivity for minimal UI rebuilds
/// - Max queue size to prevent memory issues during long gaming sessions
/// - Efficient queue management with pre-allocated capacity
///
/// Requirement 6.4: Toggle Game Mode to switch between active/inactive states
class GameModeService implements IGameModeService {
  /// Maximum number of notifications to queue (prevents memory leaks)
  static const int maxQueueSize = 50;

  bool _isActive = false;
  NotificationCallback? _notificationCallback;

  // Pre-allocate list capacity for better performance
  final List<ClipboardItem> _notificationQueue = [];

  // Broadcast stream controller for reactive UI updates
  final StreamController<bool> _isActiveController =
      StreamController<bool>.broadcast();

  @override
  bool get isActive => _isActive;

  @override
  Stream<bool> get isActiveStream => _isActiveController.stream;

  /// Set callback to handle notifications when they're flushed
  ///
  /// Requirement 6.3: Display queued notifications in sequence when deactivated
  @override
  void setNotificationCallback(NotificationCallback? callback) {
    _notificationCallback = callback;
  }

  /// Toggle Game Mode on/off
  ///
  /// Requirement 6.4: Immediately switch between active and inactive states
  /// Requirement 6.3: Display queued notifications in sequence when deactivated
  @override
  void toggle() {
    _isActive = !_isActive;
    debugPrint('GameModeService: Toggled Game Mode. New state: $_isActive');

    // Broadcast state change for reactive UI updates
    _isActiveController.add(_isActive);

    // If deactivating Game Mode, flush the notification queue
    // Requirement 6.3: Display queued notifications when Game Mode is deactivated
    if (!_isActive && _notificationQueue.isNotEmpty) {
      _flushQueueWithCallback();
    }
  }

  /// Queue a notification while Game Mode is active
  ///
  /// Requirement 6.1: Queue incoming clipboard notifications without displaying visual alerts
  ///
  /// When Game Mode is enabled, notifications are suppressed and queued
  /// to avoid interrupting gaming/fullscreen activities.
  ///
  /// Performance: Limits queue to maxQueueSize to prevent memory issues
  @override
  void queueNotification(ClipboardItem item) {
    if (_isActive) {
      debugPrint(
        'GameModeService: Queuing notification. Queue size: ${_notificationQueue.length + 1}',
      );
      // Prevent memory leaks during long gaming sessions
      if (_notificationQueue.length >= maxQueueSize) {
        // Remove oldest notification (FIFO)
        _notificationQueue.removeAt(0);
      }
      _notificationQueue.add(item);
    }
  }

  /// Flush all queued notifications and return them
  ///
  /// Called when Game Mode is deactivated to show all missed notifications
  @override
  List<ClipboardItem> flushQueue() {
    final items = List<ClipboardItem>.from(_notificationQueue);
    _notificationQueue.clear();
    return items;
  }

  /// Internal method to flush queue and trigger callbacks
  ///
  /// Requirement 6.3: Display queued notifications in sequence
  /// Fix #22: Check disposed flag to prevent race condition
  void _flushQueueWithCallback() {
    if (_isDisposed) return; // Prevent race condition during dispose

    debugPrint(
      'GameModeService: Flushing ${_notificationQueue.length} notifications',
    );
    if (_notificationCallback != null) {
      // Process notifications in order (FIFO)
      for (final item in _notificationQueue) {
        if (_isDisposed) break; // Stop if disposed mid-flush
        _notificationCallback!(item);
      }
    }
    _notificationQueue.clear();
  }

  bool _isDisposed = false; // Fix #22: Track disposal state

  /// Dispose and clean up resources to prevent memory leaks
  @override
  void dispose() {
    _isDisposed = true; // Set flag before cleanup
    _isActiveController.close();
    _notificationQueue.clear();
    _notificationCallback = null;
  }
}
