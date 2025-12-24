export 'impl/push_notification_service.dart';

/// Abstract interface for push notification service
///
/// Handles sending push notifications to mobile devices when clipboard
/// content is sent from desktop. Uses Supabase Edge Function to query
/// FCM tokens and send notifications.
abstract class IPushNotificationService {
  /// Send push notification for new clipboard content
  ///
  /// Parameters:
  /// - [clipboardId]: ID of the clipboard record
  /// - [contentPreview]: Preview of clipboard content (first 50 chars)
  /// - [deviceType]: Sender device type (windows/macos/android/ios)
  /// - [targetDeviceType]: Optional target device filter (null = all devices)
  ///
  /// Returns number of devices notified
  Future<int> sendClipboardNotification({
    required int clipboardId,
    required String contentPreview,
    required String deviceType,
    String? targetDeviceType,
  });

  /// Dispose resources
  void dispose();
}
