import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../push_notification_service.dart';

/// Concrete implementation of IPushNotificationService
///
/// Calls Supabase Edge Function to send push notifications to mobile devices.
/// Implements client-driven notification pattern for optimal performance.
class PushNotificationService implements IPushNotificationService {
  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  Future<int> sendClipboardNotification({
    required int clipboardId,
    required String contentPreview,
    required String deviceType,
    List<String>? targetDeviceTypes,
  }) async {
    try {
      final targetText = targetDeviceTypes == null
          ? 'all devices'
          : targetDeviceTypes.length == 1
              ? targetDeviceTypes.first
              : targetDeviceTypes.join(', ');

      debugPrint(
        '[PushNotification] Calling Edge Function for clipboard #$clipboardId '
        'from $deviceType to $targetText',
      );

      // Call Edge Function to send push notifications
      // This triggers FCM notifications to registered mobile devices
      final response = await _supabase.functions.invoke(
        'send-clipboard-notification',
        body: {
          'clipboard_id': clipboardId,
          'content_preview': contentPreview,
          'device_type': deviceType,
          if (targetDeviceTypes != null) 'target_device_types': targetDeviceTypes,
        },
      );

      if (response.status == 200) {
        final data = response.data as Map<String, dynamic>?;
        final devicesNotified = data?['devices_notified'] as int? ?? 0;

        debugPrint(
          '[PushNotification] ✅ Success: Notified $devicesNotified device(s) '
          '(FCM ready when mobile is implemented)',
        );

        return devicesNotified;
      } else if (response.status == 429) {
        // Server-side rate limit hit
        final data = response.data as Map<String, dynamic>?;
        final retryAfter = data?['retry_after'] as int? ?? 60;

        debugPrint(
          '[PushNotification] ⚠️ Rate limited by server. Retry after ${retryAfter}s',
        );
        return 0;
      } else {
        final data = response.data as Map<String, dynamic>?;
        final error = data?['error'] ?? 'Unknown error';

        debugPrint(
          '[PushNotification] ❌ Edge Function error (${response.status}): $error',
        );
        return 0;
      }
    } on Exception catch (e) {
      debugPrint('[PushNotification] ❌ Failed to send notification: $e');
      return 0;
    }
  }

  @override
  void dispose() {
    // No resources to dispose
  }
}
