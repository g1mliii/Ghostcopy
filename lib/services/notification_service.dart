import 'package:flutter/material.dart';

/// Type of notification to display
enum NotificationType {
  success,
  info,
  warning,
  error,
}

/// Abstract interface for universal notification service
abstract class INotificationService {
  /// Show a toast notification
  ///
  /// [message] - The text to display
  /// [type] - The type of notification (success, info, warning, error)
  /// [duration] - How long to show the toast (default: 2 seconds)
  void showToast({
    required String message,
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 2),
  });

  /// Show a notification for a clipboard item received from another device
  ///
  /// This is used by Game Mode when flushing queued notifications
  void showClipboardNotification({
    required String content,
    required String deviceType,
  });

  /// Initialize the notification service with the global context
  void initialize(GlobalKey<NavigatorState> navigatorKey);

  /// Dispose and clean up resources
  void dispose();
}
