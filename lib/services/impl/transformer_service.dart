import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../utils/content_patterns.dart';
import '../transformer_service.dart';

/// Parameters for background content detection
class _DetectionParams {
  const _DetectionParams(this.content);
  final String content;
}

/// Parameters for background transformation
class _TransformParams {
  const _TransformParams(this.content, this.type);
  final String content;
  final TransformerContentType type;
}

/// Lightweight implementation of ITransformerService
///
/// Performance optimizations:
/// - Early returns for plain text (most common case)
/// - Compiled regex patterns (reused from ContentPatterns)
/// - Priority-ordered detection (most specific first)
/// - Single-pass detection (O(n) time)
/// - Stateless (no memory leaks)
/// - Background isolates for heavy operations (>10KB content)
class TransformerService implements ITransformerService {
  // Security: Maximum content length (1MB) to prevent DoS attacks
  static const int _maxContentLength = 1048576;
  // Threshold for using background isolate (10KB)
  static const int _isolateThreshold = 10240;

  @override
  Future<ContentDetectionResult> detectContentType(String content) async {
    // Early return for empty or very short content
    if (content.isEmpty || content.length < 3) {
      return const ContentDetectionResult(
        type: TransformerContentType.plainText,
      );
    }

    // Security: Reject very large content (DoS protection)
    if (content.length > _maxContentLength) {
      return const ContentDetectionResult(
        type: TransformerContentType.plainText,
      );
    }

    // For small content (<10KB), detect synchronously to avoid isolate overhead
    if (content.length < _isolateThreshold) {
      return _detectSync(content);
    }

    // For large content (>=10KB), run in background isolate
    return compute(_detectInIsolate, _DetectionParams(content));
  }

  /// Synchronous detection for small content
  static ContentDetectionResult _detectSync(String content) {
    // Check in priority order (most specific to least specific)

    // 1. JWT tokens (very specific pattern)
    if (ContentPatterns.jwt.hasMatch(content)) {
      return const ContentDetectionResult(
        type: TransformerContentType.jwt,
        metadata: {'format': 'JWT'},
      );
    }

    // 2. JSON (validate with parser for accuracy)
    if (_isJsonSync(content)) {
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
  Future<TransformationResult> transform(
    String content,
    TransformerContentType type,
  ) async {
    // Always use isolate for transformations (JSON parsing, JWT decoding can be heavy)
    return compute(_transformInIsolate, _TransformParams(content, type));
  }

  /// Validate if content is valid JSON
  ///
  /// Performance: Uses dart:convert's json.decode which is highly optimized
  /// Security: Length limit prevents DoS attacks with very large JSON
  /// Catches parsing errors gracefully (returns false, not crash)
  static bool _isJsonSync(String content) {
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

/// Top-level function for content detection in isolate
/// Must be top-level to work with compute()
ContentDetectionResult _detectInIsolate(_DetectionParams params) {
  return TransformerService._detectSync(params.content);
}

/// Top-level function for content transformation in isolate
/// Must be top-level to work with compute()
TransformationResult _transformInIsolate(_TransformParams params) {
  switch (params.type) {
    case TransformerContentType.json:
      return _transformJsonSync(params.content);
    case TransformerContentType.jwt:
      return _transformJwtSync(params.content);
    case TransformerContentType.hexColor:
    case TransformerContentType.plainText:
      return const TransformationResult(
        transformedContent: null,
        error: 'Transformation not yet implemented for this type',
      );
  }
}

/// Transform JSON content with 2-space indentation
/// Static version for use in isolate
TransformationResult _transformJsonSync(String content) {
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
/// Static version for use in isolate
TransformationResult _transformJwtSync(String content) {
  try {
    // JWT format: header.payload.signature (3 parts separated by dots)
    final parts = content.split('.');
    if (parts.length != 3) {
      return TransformationResult(
        transformedContent: null,
        error:
            'Invalid JWT format: Expected 3 parts (header.payload.signature), got ${parts.length}',
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
    final expirationInfo = _formatJwtExpirationSync(parsed);
    final userInfo = _formatJwtUserInfoSync(parsed);

    final preview =
        '''
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
String _formatJwtExpirationSync(Map<String, dynamic> payload) {
  final expField = payload['exp'];
  if (expField == null) {
    return ' No expiration (exp claim not set)';
  }

  try {
    final expirationSeconds = expField is int
        ? expField
        : int.tryParse(expField.toString()) ?? 0;

    if (expirationSeconds == 0) {
      return ' Invalid expiration timestamp';
    }

    final expirationDate = DateTime.fromMillisecondsSinceEpoch(
      expirationSeconds * 1000,
    );
    final now = DateTime.now();
    final isExpired = expirationDate.isBefore(now);
    final status = isExpired ? '❌ EXPIRED' : '✅ VALID';
    final timeDiff = isExpired
        ? now.difference(expirationDate)
        : expirationDate.difference(now);

    return ' Expires: $expirationDate UTC $status (${_formatDurationSync(timeDiff)} ago/from now)';
  } on Exception {
    return ' Invalid expiration format';
  }
}

/// Extract and format user info from JWT payload
String _formatJwtUserInfoSync(Map<String, dynamic> payload) {
  final sub = payload['sub'] ?? payload['user_id'] ?? payload['user'];
  if (sub == null) {
    return ' No user info in token';
  }
  return ' User ID: $sub';
}

/// Format duration for human-readable display
String _formatDurationSync(Duration duration) {
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
