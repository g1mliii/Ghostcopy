import 'package:flutter/material.dart';

/// Type of notification to display
enum NotificationType { success, info, warning, error }

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

  /// Raise a system notification directly, without the in-app overlay.
  ///
  /// For the paths that have no window to put an overlay in - chiefly the
  /// Explorer "Send with GhostCopy" verb, which runs without building any UI.
  /// [showToast] cannot serve them: with no overlay it has nothing to draw
  /// into, which is why that path used to raise a native message box in the
  /// middle of the screen instead of a notification like everything else.
  Future<void> showSystemNotification({
    required String message,
    NotificationType type = NotificationType.info,
  });

  /// Show a clickable toast notification with an action button
  ///
  /// [message] - The text to display
  /// [actionLabel] - Text for the action button (e.g., "Copy", "Open")
  /// [onAction] - Callback when the action button is tapped
  /// [duration] - How long to show the toast (default: 3 seconds)
  void showClickableToast({
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    Duration duration = const Duration(seconds: 3),
  });

  /// Initialize the notification service with the global context
  void initialize(GlobalKey<NavigatorState> navigatorKey);

  /// Dispose and clean up resources
  void dispose();
}
