import '../../models/clipboard_item.dart';
import '../game_mode_service.dart';

/// Concrete implementation of IGameModeService
///
/// Game Mode suppresses notifications during fullscreen apps/games.
/// Notifications are queued and displayed when Game Mode is deactivated.
///
/// Requirement 6.4: Toggle Game Mode to switch between active/inactive states
class GameModeService implements IGameModeService {
  bool _isActive = false;
  final List<ClipboardItem> _notificationQueue = [];

  @override
  bool get isActive => _isActive;

  /// Toggle Game Mode on/off
  ///
  /// Requirement 6.4: Immediately switch between active and inactive states
  @override
  void toggle() {
    _isActive = !_isActive;

    // If deactivating Game Mode, flush the notification queue
    if (!_isActive && _notificationQueue.isNotEmpty) {
      // Notifications will be flushed by the notification service
      // This is handled externally to maintain separation of concerns
    }
  }

  /// Queue a notification while Game Mode is active
  ///
  /// When Game Mode is enabled, notifications are suppressed and queued
  /// to avoid interrupting gaming/fullscreen activities
  @override
  void queueNotification(ClipboardItem item) {
    if (_isActive) {
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

  /// Dispose and clean up resources to prevent memory leaks
  @override
  void dispose() {
    _notificationQueue.clear();
  }
}
