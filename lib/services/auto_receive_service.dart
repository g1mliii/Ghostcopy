import '../models/clipboard_item.dart';

/// Abstract interface for desktop auto-receive functionality
abstract class IAutoReceiveService {
  /// Initialize the auto-receive service
  Future<void> initialize();

  /// Handle a received clipboard item
  Future<void> onItemReceived(ClipboardItem item);

  /// Enable or disable auto-receive
  void setEnabled({required bool enabled});

  /// Check if auto-receive is enabled
  bool get isEnabled;
}
