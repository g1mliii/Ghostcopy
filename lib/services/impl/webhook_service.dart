import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../webhook_service.dart';

/// Singleton service for sending webhooks to external services
///
/// Features:
/// - Generic webhook POST for any service (Zapier, IFTTT, Notion, Slack, etc.)
/// - Retry logic with exponential backoff (3 retries max)
/// - Fire-and-forget operation (doesn't block UI)
/// - Singleton HTTP client for connection pooling
/// - No background operations (on-demand only)
class WebhookService implements IWebhookService {
  factory WebhookService() => _instance;
  WebhookService._internal();
  static final WebhookService _instance = WebhookService._internal();

  // HTTP client for connection pooling (lazy initialized to support dispose/reinit)
  http.Client? _httpClient;
  
  // Lazy getter for HTTP client - creates new instance if disposed
  http.Client get _client {
    _httpClient ??= http.Client();
    return _httpClient!;
  }

  @override
  Future<void> sendWebhook(String url, Map<String, dynamic> payload) async {
    var retries = 0;
    const maxRetries = 3;

    while (retries < maxRetries) {
      try {
        debugPrint('[WebhookService] Sending webhook (attempt ${retries + 1}/$maxRetries)');

        final response = await _client
            .post(
              Uri.parse(url),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          debugPrint('[WebhookService] ✅ Webhook sent successfully (${response.statusCode})');
          return; // Success
        }

        debugPrint(
          '[WebhookService] ⚠️  Webhook failed with status ${response.statusCode}',
        );
      } on Exception catch (e) {
        debugPrint('[WebhookService] ❌ Webhook error: $e');
      }

      retries++;
      if (retries >= maxRetries) {
        debugPrint('[WebhookService] ❌ Failed after $maxRetries retries');
        return;
      }

      // Exponential backoff: 2s, 4s, 8s
      final backoffDuration = Duration(seconds: retries * 2);
      debugPrint(
        '[WebhookService] ⏳ Retrying in ${backoffDuration.inSeconds}s...',
      );
      await Future<void>.delayed(backoffDuration);
    }
  }

  @override
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
    debugPrint('[WebhookService] ✅ Disposed');
  }
}
