import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../url_shortener_service.dart';

/// Singleton service for URL shortening using TinyURL API
///
/// Features:
/// - TinyURL API integration (free, no API key required)
/// - Singleton HTTP client for connection pooling
/// - Timeout handling (5 seconds)
/// - Graceful fallback to original URL on failure
/// - No background operations (on-demand only)
class UrlShortenerService implements IUrlShortenerService {
  factory UrlShortenerService() => _instance;
  UrlShortenerService._internal();
  static final UrlShortenerService _instance = UrlShortenerService._internal();

  // HTTP client for connection pooling (lazy initialized to support dispose/reinit)
  http.Client? _httpClient;
  
  // Lazy getter for HTTP client - creates new instance if disposed
  http.Client get _client {
    _httpClient ??= http.Client();
    return _httpClient!;
  }

  // TinyURL API endpoint
  static const String _apiEndpoint = 'https://tinyurl.com/api-create.php';

  @override
  Future<String> shortenUrl(String url) async {
    try {
      // URL encode the long URL
      final encoded = Uri.encodeComponent(url);
      final apiUrl = '$_apiEndpoint?url=$encoded';

      debugPrint('[UrlShortenerService] Shortening URL: ${url.length > 50 ? '${url.substring(0, 50)}...' : url}');

      final response = await _client
          .get(Uri.parse(apiUrl))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final shortened = response.body.trim();
        debugPrint('[UrlShortenerService] ✅ Shortened to: $shortened');
        return shortened;
      }

      debugPrint('[UrlShortenerService] ⚠️  API returned status ${response.statusCode}');
      return url; // Fallback to original
    } on Exception catch (e) {
      debugPrint('[UrlShortenerService] ❌ Failed to shorten URL: $e');
      return url; // Fallback to original
    }
  }

  @override
  bool isUrl(String text) {
    // Match HTTP/HTTPS URLs
    final urlPattern = RegExp(
      r'^https?://[^\s]+$',
      caseSensitive: false,
    );
    return urlPattern.hasMatch(text.trim());
  }

  @override
  void dispose() {
    _httpClient?.close();
    _httpClient = null;
    debugPrint('[UrlShortenerService] ✅ Disposed');
  }
}
