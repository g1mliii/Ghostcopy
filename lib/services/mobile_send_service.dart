/// Abstract interface for mobile clipboard sending
abstract class IMobileSendService {
  /// Send content to the cloud
  Future<void> sendContent(String content);
  
  /// Read clipboard content (only works when app is in foreground)
  Future<String?> readClipboard();
}
