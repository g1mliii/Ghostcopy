export 'impl/url_shortener_service.dart';

/// Abstract interface for URL shortening service
abstract class IUrlShortenerService {
  /// Shorten a URL using TinyURL API
  ///
  /// Returns the shortened URL on success, or the original URL on failure.
  /// Includes timeout and error handling for network issues.
  Future<String> shortenUrl(String url);

  /// Check if a string is a valid URL
  ///
  /// Validates HTTP/HTTPS URLs with basic pattern matching.
  bool isUrl(String text);

  /// Dispose resources
  void dispose();
}
