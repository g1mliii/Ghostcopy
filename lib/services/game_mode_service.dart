import '../models/clipboard_item.dart';

/// Abstract interface for Game Mode management
abstract class IGameModeService {
  /// Check if Game Mode is currently active
  bool get isActive;
  
  /// Toggle Game Mode on/off
  void toggle();
  
  /// Queue a notification while Game Mode is active
  void queueNotification(ClipboardItem item);
  
  /// Flush all queued notifications and return them
  List<ClipboardItem> flushQueue();
}
