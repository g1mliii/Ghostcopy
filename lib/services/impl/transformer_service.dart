import 'dart:convert';

import '../../utils/content_patterns.dart';
import '../transformer_service.dart';

/// Lightweight implementation of ITransformerService
///
/// Performance optimizations:
/// - Early returns for plain text (most common case)
/// - Compiled regex patterns (reused from ContentPatterns)
/// - Priority-ordered detection (most specific first)
/// - Single-pass detection (O(n) time)
/// - Stateless (no memory leaks)
class TransformerService implements ITransformerService {
  // Security: Maximum content length (1MB) to prevent DoS attacks
  static const int _maxContentLength = 1048576;

  @override
  ContentDetectionResult detectContentType(String content) {
    // Early return for empty or very short content
    if (content.isEmpty || content.length < 3) {
      return const ContentDetectionResult(type: TransformerContentType.plainText);
    }

    // Security: Reject very large content (DoS protection)
    if (content.length > _maxContentLength) {
      return const ContentDetectionResult(type: TransformerContentType.plainText);
    }

    // Check in priority order (most specific to least specific)

    // 1. JWT tokens (very specific pattern)
    if (ContentPatterns.jwt.hasMatch(content)) {
      return const ContentDetectionResult(
        type: TransformerContentType.jwt,
        metadata: {'format': 'JWT'},
      );
    }

    // 2. JSON (validate with parser for accuracy)
    if (_isJson(content)) {
      return const ContentDetectionResult(
        type: TransformerContentType.json,
        metadata: {'valid': true},
      );
    }

    // 3. Hex colors (simple pattern)
    final hexMatch = ContentPatterns.hexColor.firstMatch(content);
    if (hexMatch != null) {
      final colorValue = hexMatch.group(0)!;
      return ContentDetectionResult(
        type: TransformerContentType.hexColor,
        metadata: {'color': colorValue, 'length': colorValue.length - 1},
      );
    }

    // Default: plain text
    return const ContentDetectionResult(type: TransformerContentType.plainText);
  }

  @override
  TransformationResult transform(String content, TransformerContentType type) {
    switch (type) {
      case TransformerContentType.json:
        return _transformJson(content);
      case TransformerContentType.jwt:
        return _transformJwt(content);
      case TransformerContentType.hexColor:
      case TransformerContentType.plainText:
        return const TransformationResult(
          transformedContent: null,
          error: 'Transformation not yet implemented for this type',
        );
    }
  }

  /// Transform JSON content with 2-space indentation
  ///
  /// Parses the JSON string and re-encodes it with pretty formatting.
  /// Performance: Uses dart:convert's JsonEncoder which is optimized
  /// Error handling: Catches and returns graceful error messages
  TransformationResult _transformJson(String content) {
    try {
      // Parse the JSON to validate and get the data structure
      final parsed = json.decode(content);

      // Re-encode with 2-space indentation for pretty printing
      final prettified = JsonEncoder.withIndent('  ').convert(parsed);

      return TransformationResult(
        transformedContent: prettified,
        preview: 'Formatted JSON with 2-space indentation',
      );
    } on FormatException catch (e) {
      return TransformationResult(
        transformedContent: null,
        error: 'Invalid JSON: ${e.message}',
      );
    } on Exception catch (e) {
      return TransformationResult(
        transformedContent: null,
        error: 'Error prettifying JSON: $e',
      );
    }
  }

  /// Decode JWT token and display payload
  ///
  /// Extracts and decodes the JWT payload without verification.
  /// JWT tokens are NOT modified (transformedContent = null).
  /// Displays the decoded payload as formatted JSON for user review.
  /// Security: Only decodes payload, does NOT verify signature
  /// Error handling: Catches and returns graceful error messages
  TransformationResult _transformJwt(String content) {
    try {
      // JWT format: header.payload.signature (3 parts separated by dots)
      final parts = content.split('.');
      if (parts.length != 3) {
        return TransformationResult(
          transformedContent: null,
          error: 'Invalid JWT format: Expected 3 parts (header.payload.signature), got ${parts.length}',
        );
      }

      // Security: Validate base64url encoding
      final payloadPart = parts[1];
      if (payloadPart.isEmpty) {
        return const TransformationResult(
          transformedContent: null,
          error: 'Invalid JWT: Payload part is empty',
        );
      }

      // Decode base64url payload
      // Note: base64url uses - and _ instead of + and /
      // Add padding if necessary (base64 requires padding to multiple of 4)
      final normalized = base64Url.normalize(payloadPart);

      late final List<int> decodedBytes;
      try {
        decodedBytes = base64Url.decode(normalized);
      } on FormatException {
        return const TransformationResult(
          transformedContent: null,
          error: 'Invalid JWT: Payload is not valid base64url encoding',
        );
      }

      // Convert bytes to UTF-8 string
      final payloadJson = utf8.decode(decodedBytes);

      // Parse payload as JSON
      final parsed = json.decode(payloadJson);

      // Verify it's a Map (object)
      if (parsed is! Map<String, dynamic>) {
        return const TransformationResult(
          transformedContent: null,
          error: 'Invalid JWT: Payload is not a JSON object',
        );
      }

      // Format payload for display
      final prettyPayload = JsonEncoder.withIndent('  ').convert(parsed);

      // Extract useful info for preview
      final expirationInfo = _formatJwtExpiration(parsed);
      final userInfo = _formatJwtUserInfo(parsed);

      final preview = '''
$prettyPayload

$expirationInfo
$userInfo''';

      return TransformationResult(
        transformedContent: null, // Don't modify JWT itself
        preview: preview,
      );
    } on Exception catch (e) {
      return TransformationResult(
        transformedContent: null,
        error: 'Error decoding JWT: $e',
      );
    }
  }

  /// Extract and format expiration info from JWT payload
  /// Returns a formatted string with expiration timestamp and human-readable date
  String _formatJwtExpiration(Map<String, dynamic> payload) {
    final expField = payload['exp'];
    if (expField == null) {
      return '⏰ No expiration (exp claim not set)';
    }

    try {
      final expirationSeconds = expField is int
          ? expField
          : int.tryParse(expField.toString()) ?? 0;

      if (expirationSeconds == 0) {
        return '⏰ Invalid expiration timestamp';
      }

      final expirationDate =
          DateTime.fromMillisecondsSinceEpoch(expirationSeconds * 1000);
      final now = DateTime.now();
      final isExpired = expirationDate.isBefore(now);
      final status = isExpired ? '❌ EXPIRED' : '✅ VALID';
      final timeDiff = isExpired
          ? now.difference(expirationDate)
          : expirationDate.difference(now);

      return '⏰ Expires: $expirationDate UTC $status (${_formatDuration(timeDiff)} ago/from now)';
    } on Exception {
      return '⏰ Invalid expiration format';
    }
  }

  /// Extract and format user info from JWT payload
  /// Common JWT claims: sub (subject/user ID), preferred_username, email, etc.
  String _formatJwtUserInfo(Map<String, dynamic> payload) {
    final sub = payload['sub'] ?? payload['user_id'] ?? payload['user'];
    if (sub == null) {
      return '👤 No user info in token';
    }
    return '👤 User ID: $sub';
  }

  /// Format duration for human-readable display
  String _formatDuration(Duration duration) {
    if (duration.inDays > 0) {
      return '${duration.inDays}d';
    } else if (duration.inHours > 0) {
      return '${duration.inHours}h';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  /// Validate if content is valid JSON
  ///
  /// Performance: Uses dart:convert's json.decode which is highly optimized
  /// Security: Length limit prevents DoS attacks with very large JSON
  /// Catches parsing errors gracefully (returns false, not crash)
  bool _isJson(String content) {
    // Security: Reject very large JSON (additional safety check)
    // Already checked in detectContentType, but defense in depth
    if (content.length > _maxContentLength) {
      return false;
    }

    // Quick regex check first (fast rejection)
    if (!ContentPatterns.json.hasMatch(content)) {
      return false;
    }

    // Validate by parsing (definitive check)
    try {
      json.decode(content);
      return true;
    } on FormatException {
      return false;
    }
  }
}
