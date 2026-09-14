import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  // Active retry timer (cancellable to prevent leaks)
  Timer? _retryTimer;

  // The future a pending retry is waiting on, so dispose() can release it.
  Completer<void>? _retryCompleter;

  bool _disposed = false;

  // Lazy getter for HTTP client - creates new instance if disposed
  http.Client get _client {
    _httpClient ??= http.Client();
    return _httpClient!;
  }

  @override
  Future<void> sendWebhook(String url, Map<String, dynamic> payload) async {
    // SECURITY: Validate URL to prevent SSRF attacks
    final uri = Uri.tryParse(url);
    if (uri == null) {
      debugPrint('[WebhookService] ❌ Invalid URL format: $url');
      throw Exception('Invalid webhook URL format');
    }

    // Only allow HTTPS protocol (HTTP is insecure for webhook payloads)
    if (uri.scheme != 'https') {
      debugPrint('[WebhookService] ❌ Invalid URL scheme: ${uri.scheme} (HTTPS required)');
      throw Exception('Webhook URL must use https protocol');
    }

    // Validate host against SSRF protection
    await _validateHost(uri.host);

    var retries = 0;
    const maxRetries = 3;

    while (retries < maxRetries) {
      try {
        debugPrint('[WebhookService] Sending webhook (attempt ${retries + 1}/$maxRetries)');

        // SECURITY: Disable automatic redirect following to prevent SSRF bypass
        // Redirects could bypass our private IP validation
        final request = http.Request('POST', uri)
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(payload);

        final streamedResponse = await _client
            .send(request)
            .timeout(const Duration(seconds: 10));
        final response = await http.Response.fromStream(streamedResponse);

        // Success: 2xx status codes
        if (response.statusCode >= 200 && response.statusCode < 300) {
          debugPrint('[WebhookService] ✅ Webhook sent successfully (${response.statusCode})');
          return;
        }

        // Reject redirects: 3xx status codes
        // We don't follow redirects to prevent SSRF attacks via redirect chains
        if (response.statusCode >= 300 && response.statusCode < 400) {
          debugPrint(
            '[WebhookService] ❌ Webhook returned redirect (${response.statusCode}) - redirects not allowed for security',
          );
          throw Exception('Webhook redirects are not allowed for security reasons');
        }

        // A 4xx other than "slow down" or "timed out" means the request itself
        // is wrong; replaying it twice more only wastes the user's battery and
        // the endpoint's quota.
        final isRetryable =
            response.statusCode == 408 ||
            response.statusCode == 429 ||
            response.statusCode >= 500;

        debugPrint(
          '[WebhookService] ⚠️  Webhook failed with status ${response.statusCode}',
        );

        if (!isRetryable) {
          debugPrint('[WebhookService] ❌ Not retryable - giving up');
          return;
        }
      } on Exception catch (e) {
        debugPrint('[WebhookService] ❌ Webhook error: $e');
      }

      retries++;
      if (retries >= maxRetries) {
        debugPrint('[WebhookService] ❌ Failed after $maxRetries retries');
        return;
      }

      // Backoff between the 3 attempts: 2s then 4s.
      final backoffDuration = Duration(seconds: 1 << retries);
      debugPrint(
        '[WebhookService] ⏳ Retrying in ${backoffDuration.inSeconds}s...',
      );

      // Cancellable timer rather than Future.delayed, so dispose() can cut a
      // pending retry short. dispose() must also complete the completer: it is
      // the timer callback that would have done so, and cancelling the timer
      // alone left this await hanging forever.
      final completer = Completer<void>();
      _retryCompleter = completer;
      _retryTimer = Timer(backoffDuration, () {
        if (!completer.isCompleted) completer.complete();
      });
      await completer.future;

      if (_disposed) {
        debugPrint('[WebhookService] Aborting retries - service disposed');
        return;
      }
    }
  }

  /// Validate host against SSRF protection rules
  ///
  /// Throws Exception if host resolves to a private network or loopback.
  ///
  /// This used to pattern-match the host STRING against a list of private-range
  /// regexes, which only catches an attacker who spells the address out in
  /// dotted-quad. A plain hostname pointing at an internal address
  /// (`metadata.google.internal`, any intranet name) or an address written in
  /// decimal/octal sailed straight through. Resolving first and judging the
  /// ADDRESSES closes all of those at once, because it inspects the thing the
  /// socket will actually connect to.
  Future<void> _validateHost(String host) async {
    final List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
    } on Object catch (e) {
      // Fail closed: an unresolvable host is not a host we should post to.
      debugPrint('[WebhookService] ❌ Could not resolve $host: $e');
      throw Exception('Webhook URL host could not be resolved');
    }

    if (addresses.isEmpty) {
      throw Exception('Webhook URL host could not be resolved');
    }

    for (final address in addresses) {
      if (_isPrivateAddress(address)) {
        debugPrint(
          '[WebhookService] ❌ Blocked private address for $host: '
          '${address.address}',
        );
        throw Exception(
          'Webhook URL cannot target private networks or localhost',
        );
      }
    }
  }

  /// Whether [address] is loopback, link-local, or otherwise not routable.
  ///
  /// Judged on raw bytes rather than text so every spelling of an address
  /// reduces to the same answer.
  static bool _isPrivateAddress(InternetAddress address) {
    if (address.isLoopback) return true;

    final bytes = address.rawAddress;

    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      return _isPrivateIPv4(bytes);
    }

    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      // Unspecified (::)
      if (bytes.every((b) => b == 0)) return true;
      // Unique local fc00::/7
      if ((bytes[0] & 0xFE) == 0xFC) return true;
      // Link-local fe80::/10
      if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return true;
      // IPv4-mapped ::ffff:a.b.c.d - judge the embedded IPv4, or an internal
      // target could be reached simply by writing it in IPv6 form.
      final isV4Mapped =
          bytes.take(10).every((b) => b == 0) &&
          bytes[10] == 0xFF &&
          bytes[11] == 0xFF;
      if (isV4Mapped) return _isPrivateIPv4(bytes.sublist(12));
    }

    return false;
  }

  static bool _isPrivateIPv4(List<int> b) {
    // 0.0.0.0/8 - "this network"
    if (b[0] == 0) return true;
    // 10.0.0.0/8
    if (b[0] == 10) return true;
    // 127.0.0.0/8 - loopback
    if (b[0] == 127) return true;
    // 169.254.0.0/16 - link-local, covers the cloud metadata endpoint
    if (b[0] == 169 && b[1] == 254) return true;
    // 172.16.0.0/12
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    // 192.168.0.0/16
    if (b[0] == 192 && b[1] == 168) return true;
    // 100.64.0.0/10 - carrier-grade NAT
    if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
    // 192.0.0.0/24 - IETF protocol assignments
    if (b[0] == 192 && b[1] == 0 && b[2] == 0) return true;
    // 198.18.0.0/15 - benchmarking
    if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return true;
    // 224.0.0.0/4 multicast and 240.0.0.0/4 reserved
    if (b[0] >= 224) return true;

    return false;
  }

  @override
  void dispose() {
    _disposed = true;

    // Cancel any active retry timer to prevent leaks
    _retryTimer?.cancel();
    _retryTimer = null;

    // Release whoever is awaiting that timer. Without this the send loop stays
    // parked on a future nothing will ever complete.
    final pending = _retryCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    _retryCompleter = null;

    // Close HTTP client to release connections
    _httpClient?.close();
    _httpClient = null;

    debugPrint('[WebhookService] ✅ Disposed');
  }
}
