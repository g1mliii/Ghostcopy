/// Types of content that can be transformed
enum ContentType {
  json,
  jwt,
  hexColor,
  plainText;
}

/// Result of content type detection
class ContentDetectionResult {
  const ContentDetectionResult({
    required this.type,
    this.metadata,
  });

  final ContentType type;
  final Map<String, dynamic>? metadata; // e.g., {"valid": true, "length": 123}

  bool get isTransformable =>
      type == ContentType.json ||
      type == ContentType.jwt ||
      type == ContentType.hexColor;
}

/// Transformation result with enhanced content
class TransformationResult {
  const TransformationResult({
    required this.transformedContent,
    this.preview,
    this.error,
  });

  final String? transformedContent; // e.g., prettified JSON
  final String? preview; // e.g., JWT payload, color value
  final String? error; // Error message if transformation failed

  bool get isSuccess => transformedContent != null && error == null;
}

/// Service for detecting and transforming clipboard content
///
/// Future implementation will include:
/// - JSON detection and prettification (2-space indentation)
/// - JWT token detection and decoding (payload + expiration)
/// - Hex color detection and preview (#RGB, #RRGGBB, #RRGGBBAA)
///
/// Architecture:
/// - Stateless service (no memory leaks)
/// - Fast detection (reuses patterns from SecurityService where applicable)
/// - Graceful error handling (invalid JSON/JWT returns error, not crash)
///
/// Integration with SecurityService:
/// - SecurityService blocks auto-send for sensitive data
/// - TransformerService enhances display/editing of detected content types
/// - JWT tokens are BOTH blocked by security AND can be decoded for viewing
///
/// UI Integration points:
/// - SpotlightScreen will show transform buttons when content is transformable
/// - JSON: "Prettify" button → formats with 2-space indentation
/// - JWT: Auto-show decoded payload preview below text field
/// - Hex Color: Show color square preview next to hex code
// ignore: one_member_abstracts
abstract class ITransformerService {
  /// Detect the type of content in the clipboard
  ///
  /// Returns ContentDetectionResult with type and optional metadata
  /// Will be implemented in tasks 14.1-14.4
  ContentDetectionResult detectContentType(String content);

  /// Transform content based on its detected type
  ///
  /// For JSON: Returns prettified JSON with 2-space indentation
  /// For JWT: Returns decoded payload as formatted JSON
  /// For Hex Color: Returns color value and RGB breakdown
  ///
  /// Will be implemented in tasks 15-16
  TransformationResult transform(String content, ContentType type);
}
