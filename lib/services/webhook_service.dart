export 'impl/webhook_service.dart';

/// Abstract interface for webhook service
abstract class IWebhookService {
  /// Send webhook POST request with JSON payload
  ///
  /// Includes retry logic with exponential backoff (3 retries max).
  /// Fire-and-forget operation that doesn't block UI.
  Future<void> sendWebhook(String url, Map<String, dynamic> payload);

  /// Dispose resources
  void dispose();
}
