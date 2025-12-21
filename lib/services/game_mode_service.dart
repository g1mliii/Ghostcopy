import '../models/clipboard_item.dart';

/// Callback type for handling flushed notifications
typedef NotificationCallback = void Function(ClipboardItem item);

/// Abstract interface for Game Mode management
abstract class IGameModeService {
  /// Check if Game Mode is currently active
  bool get isActive;

  /// Stream of Game Mode state changes for reactive UI updates
  Stream<bool> get isActiveStream;

  /// Toggle Game Mode on/off
  void toggle();

  /// Queue a notification while Game Mode is active
  ///
  /// Requirement 6.1: Queue incoming clipboard notifications without displaying visual alerts
  void queueNotification(ClipboardItem item);

  /// Set callback to handle notifications when they're flushed
  ///
  /// Requirement 6.3: Display queued notifications in sequence when deactivated
  void setNotificationCallback(NotificationCallback? callback);

  /// Flush all queued notifications and return them
  ///
  /// This is called internally when deactivating Game Mode
  List<ClipboardItem> flushQueue();

  /// Dispose and clean up resources
  void dispose();
}
