import '../security_service.dart';

/// Lightweight implementation of ISecurityService
///
/// Performance optimizations:
/// - Early returns for common safe patterns (plain text, short strings)
/// - Compiled regex patterns (initialized once)
/// - Single-pass detection (O(n) time)
/// - No memory allocations for safe content
/// - Stateless (no memory leaks)
class SecurityService implements ISecurityService {
  // Security: Maximum content length (1MB) to prevent DoS attacks
  static const int _maxContentLength = 1048576;

  // Compiled regex patterns (initialized once, reused for all checks)
  // API key prefixes from common providers
  static final _apiKeyPattern = RegExp(
    r'(sk_live_|pk_live_|sk_test_|pk_test_|ghp_|gho_|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35})\w*',
  );

  // JWT token pattern: header.payload.signature (base64 with dots)
  static final _jwtPattern = RegExp(
    r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
  );

  // Credit card pattern: 13-19 digits with optional spaces/dashes
  // Matches: 4532148803436467 or 4532-1488-0343-6467 or 4532 1488 0343 6467
  static final _creditCardPattern = RegExp(
    r'\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}',
  );

  @override
  DetectionResult detectSensitiveData(String content) {
    // Early return for empty or very short content (performance optimization)
    if (content.isEmpty || content.length < 10) {
      return DetectionResult.safe;
    }

    // Security: Block very large content to prevent DoS attacks
    // Treat as sensitive (safer to block than risk crash)
    if (content.length > _maxContentLength) {
      return const DetectionResult(
        isSensitive: true,
        type: SensitiveDataType.highEntropy,
        reason: 'Content too large for safety analysis (>1MB)',
      );
    }

    // Check 1: API Keys (fast regex check)
    if (_apiKeyPattern.hasMatch(content)) {
      return const DetectionResult(
        isSensitive: true,
        type: SensitiveDataType.apiKey,
        reason: 'Detected API key pattern',
      );
    }

    // Check 2: JWT Tokens (fast regex check)
    if (_jwtPattern.hasMatch(content)) {
      return const DetectionResult(
        isSensitive: true,
        type: SensitiveDataType.jwtToken,
        reason: 'Detected JWT token',
      );
    }

    // Check 3: Credit Cards (regex + Luhn validation)
    final creditCardMatch = _creditCardPattern.firstMatch(content);
    if (creditCardMatch != null) {
      // Extract only digits from the matched string
      final matchedText = creditCardMatch.group(0)!;
      final digits = matchedText.replaceAll(RegExp('[^0-9]'), '');

      // Validate with Luhn algorithm
      if (digits.length >= 13 && digits.length <= 19 && _isValidLuhn(digits)) {
        return const DetectionResult(
          isSensitive: true,
          type: SensitiveDataType.creditCard,
          reason: 'Detected credit card number',
        );
      }
    }

    // Check 4: High-entropy secrets (lightweight entropy check)
    // Skip if content is too long (performance) or too short (false positives)
    if (content.length >= 20 && content.length <= 500) {
      if (_hasHighEntropy(content)) {
        return const DetectionResult(
          isSensitive: true,
          type: SensitiveDataType.highEntropy,
          reason: 'Detected high-entropy secret (possible password/key)',
        );
      }
    }

    // No sensitive data detected
    return DetectionResult.safe;
  }

  /// Luhn algorithm for credit card validation (efficient O(n) check)
  bool _isValidLuhn(String digits) {
    if (digits.length < 13 || digits.length > 19) return false;

    var sum = 0;
    var alternate = false;

    // Traverse digits from right to left
    for (var i = digits.length - 1; i >= 0; i--) {
      var digit = int.tryParse(digits[i]);
      if (digit == null) return false;

      if (alternate) {
        digit *= 2;
        if (digit > 9) digit -= 9;
      }

      sum += digit;
      alternate = !alternate;
    }

    return sum % 10 == 0;
  }

  /// Lightweight entropy check for detecting random-looking strings
  ///
  /// Detects high-entropy content by checking:
  /// - Character diversity (uppercase, lowercase, digits, special chars)
  /// - Minimal spaces (keys/passwords rarely have spaces)
  /// - Sufficient length without being too long
  ///
  /// Performance: O(n) single pass, early return
  bool _hasHighEntropy(String content) {
    // Skip if content has spaces (likely natural text, not a key/password)
    if (content.contains(' ')) return false;

    var hasUpper = false;
    var hasLower = false;
    var hasDigit = false;
    var hasSpecial = false;
    var charCount = 0;

    // Single pass through string
    for (var i = 0; i < content.length && charCount < 100; i++) {
      final char = content.codeUnitAt(i);

      if (char >= 65 && char <= 90) {
        hasUpper = true; // A-Z
      } else if (char >= 97 && char <= 122) {
        hasLower = true; // a-z
      } else if (char >= 48 && char <= 57) {
        hasDigit = true; // 0-9
      } else if (char > 32 && char < 127) {
        hasSpecial = true; // Special chars
      }

      charCount++;

      // Early return if we've found high diversity
      if (hasUpper && hasLower && hasDigit && hasSpecial) {
        return true; // High entropy detected
      }
    }

    // Require at least 3 of 4 character types for high entropy
    final diversity = (hasUpper ? 1 : 0) +
        (hasLower ? 1 : 0) +
        (hasDigit ? 1 : 0) +
        (hasSpecial ? 1 : 0);

    return diversity >= 3;
  }
}
