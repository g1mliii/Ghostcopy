/// Types of sensitive data that can be detected
enum SensitiveDataType {
  apiKey('API Key'),
  jwtToken('JWT Token'),
  creditCard('Credit Card'),
  highEntropy('High-Entropy Secret');

  const SensitiveDataType(this.label);
  final String label;
}

/// Result of sensitive data detection
class DetectionResult {
  const DetectionResult({
    required this.isSensitive,
    this.type,
    this.reason,
  });

  final bool isSensitive;
  final SensitiveDataType? type;
  final String? reason;

  /// Safe result (no sensitive data detected)
  static const safe = DetectionResult(isSensitive: false);
}

/// Lightweight service for detecting sensitive data in clipboard content
///
/// Performance characteristics:
/// - O(n) time complexity (single pass through content)
/// - Zero allocations for safe content (early returns)
/// - Minimal regex usage (compiled once, reused)
/// - No state (stateless/thread-safe)
// ignore: one_member_abstracts
abstract class ISecurityService {
  /// Detect sensitive data in clipboard content
  ///
  /// Returns DetectionResult indicating if content contains:
  /// - API keys (GitHub, AWS, Stripe, etc.)
  /// - JWT tokens
  /// - Credit card numbers
  /// - High-entropy secrets (passwords, keys)
  DetectionResult detectSensitiveData(String content);
}
