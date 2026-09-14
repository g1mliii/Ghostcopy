import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../utils/content_patterns.dart';
import '../security_service.dart';

/// Lightweight implementation of ISecurityService
///
/// Performance optimizations:
/// - Early returns for common safe patterns (plain text, short strings)
/// - Compiled regex patterns (initialized once)
/// - Single-pass detection (O(n) time)
/// - No memory allocations for safe content
/// - Stateless (no memory leaks)
/// - Background execution via compute() to prevent main thread blocking
class SecurityService implements ISecurityService {
  // Security: Maximum content length (1MB) to prevent DoS attacks
  static const int _maxContentLength = 1048576;

  // Detection patterns live in ContentPatterns, which documents them as
  // "Used by: SecurityService" - but this class used to keep its own private
  // copies of all three, so the shared ones were dead and the two definitions
  // could drift apart unnoticed. There is now one definition of each.
  static final _apiKeyPattern = ContentPatterns.apiKey;
  static final _jwtPattern = ContentPatterns.jwt;
  static final _creditCardPattern = ContentPatterns.creditCard;

  // Compiled once rather than per call. The entropy and structure checks run on
  // every clipboard change, and `_nonDigits` used to be compiled inside the
  // credit-card match loop - once per candidate, so digit-heavy text (a CSV, a
  // log) paid for hundreds of compiles.
  static final _nonDigits = RegExp('[^0-9]');
  static final _whitespace = RegExp(r'\s');
  static final _urlScheme = RegExp('^[a-zA-Z][a-zA-Z0-9+.-]*://');
  static final _windowsPath = RegExp(r'^[a-zA-Z]:[/\\]');
  static final _dottedIdentifier = RegExp(r'^[\w.-]+\.[a-zA-Z]{2,}$');

  @override
  DetectionResult detectSensitiveData(String content) {
    return _detectSensitiveDataSync(content);
  }

  /// Async version that runs in background isolate (non-blocking)
  /// Use this for large content or when called from UI thread
  @override
  Future<DetectionResult> detectSensitiveDataAsync(String content) async {
    // For very short content, avoid isolate overhead
    if (content.length < 1000) {
      return _detectSensitiveDataSync(content);
    }

    // Run in background isolate using compute()
    return compute(_detectSensitiveDataSync, content);
  }

  /// Static detection logic (can run in isolate)
  static DetectionResult _detectSensitiveDataSync(String content) {
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
    //
    // Every candidate, not just the first: an order number or phone number
    // earlier in the text used to consume the single check and hide a real card
    // further down.
    for (final match in _creditCardPattern.allMatches(content)) {
      final digits = match.group(0)!.replaceAll(_nonDigits, '');

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
  static bool _isValidLuhn(String digits) {
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

  /// Whether [content] looks like a random secret rather than ordinary text.
  ///
  /// The previous version counted character CLASSES: anything with upper,
  /// lower, digit and one "special" was called a secret, where "special" was
  /// any printable non-alphanumeric - which includes `.`, `/`, `:`, `-` and
  /// `_`. Every URL, file path and dotted identifier therefore matched, so
  /// ordinary links were withheld from auto-send. Class diversity simply does
  /// not distinguish `https://example.com/Path123` from a real key.
  ///
  /// Shannon entropy over the actual character distribution does, because a
  /// random secret spreads its characters out and human-readable text does not.
  /// The class check is kept only as a cheap precondition.
  static bool _hasHighEntropy(String content) {
    // Whitespace means prose or structured text, not a key.
    if (content.contains(_whitespace)) return false;

    // Something recognisably structured rather than random. Checked before the
    // entropy maths because a long URL can genuinely score above the threshold.
    if (_looksStructured(content)) return false;

    var hasUpper = false;
    var hasLower = false;
    var hasDigit = false;

    final counts = <int, int>{};
    for (var i = 0; i < content.length; i++) {
      final char = content.codeUnitAt(i);
      counts[char] = (counts[char] ?? 0) + 1;

      if (char >= 65 && char <= 90) {
        hasUpper = true;
      } else if (char >= 97 && char <= 122) {
        hasLower = true;
      } else if (char >= 48 && char <= 57) {
        hasDigit = true;
      }
    }

    // A secret worth blocking mixes at least letters and digits.
    if (!(hasDigit && (hasUpper || hasLower))) return false;

    // Shannon entropy in bits per character.
    final length = content.length;
    var entropy = 0.0;
    for (final count in counts.values) {
      final p = count / length;
      entropy -= p * (math.log(p) / math.ln2);
    }

    return entropy >= _entropyBitsPerCharThreshold;
  }

  /// Bits per character above which a string is treated as random.
  ///
  /// Base64/hex secrets land around 4.5-6.0; English words and identifiers sit
  /// well below 4.0. 4.2 leaves room on both sides.
  static const double _entropyBitsPerCharThreshold = 4.2;

  /// Recognisable structure that rules out "random secret".
  static bool _looksStructured(String content) {
    // URLs, including scheme-relative ones.
    if (_urlScheme.hasMatch(content)) return true;
    if (content.startsWith('//')) return true;

    // Filesystem paths, POSIX and Windows.
    if (content.startsWith('/') || content.startsWith(r'\\')) return true;
    if (_windowsPath.hasMatch(content)) return true;

    // Dotted or slashed identifiers: package names, domains, import paths.
    if (_dottedIdentifier.hasMatch(content)) return true;

    return false;
  }
}
