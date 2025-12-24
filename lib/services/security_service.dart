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
abstract class ISecurityService {
  /// Detect sensitive data in clipboard content (synchronous)
  ///
  /// Returns DetectionResult indicating if content contains:
  /// - API keys (GitHub, AWS, Stripe, etc.)
  /// - JWT tokens
  /// - Credit card numbers
  /// - High-entropy secrets (passwords, keys)
  ///
  /// For small content (<1000 chars), this is fine to call on main thread.
  /// For large content, prefer detectSensitiveDataAsync() to avoid blocking.
  DetectionResult detectSensitiveData(String content);

  /// Detect sensitive data in clipboard content (asynchronous, non-blocking)
  ///
  /// Runs detection in background isolate to prevent UI blocking.
  /// Use this when called from UI thread or for large content.
  Future<DetectionResult> detectSensitiveDataAsync(String content);
}
