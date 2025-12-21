/// Shared regex patterns for content detection
///
/// These patterns are used by both SecurityService and TransformerService:
/// - SecurityService: Detects sensitive data to block auto-send
/// - TransformerService: Detects transformable content to show enhancements
///
/// Compiled once at class initialization for performance (static final)
class ContentPatterns {
  // Private constructor to prevent instantiation (utility class)
  ContentPatterns._();

  /// JWT token pattern: header.payload.signature (base64 with dots)
  ///
  /// Used by:
  /// - SecurityService: Block auto-send of JWT tokens
  /// - TransformerService: Decode and display JWT payload
  static final jwt = RegExp(
    r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
  );

  /// JSON pattern: Detect valid JSON objects or arrays
  ///
  /// Used by:
  /// - TransformerService: Prettify JSON with 2-space indentation
  ///
  /// Note: This is a simplified pattern. Full JSON validation requires parsing.
  /// Pattern matches: {"key": "value"} or [1, 2, 3]
  ///
  /// Security: Uses non-greedy quantifier (.*?) to prevent ReDoS attacks
  static final json = RegExp(
    r'^\s*[\{\[].*?[\}\]]\s*$',
    dotAll: true,
  );

  /// Hex color pattern: #RGB, #RRGGBB, #RRGGBBAA
  ///
  /// Used by:
  /// - TransformerService: Show color preview square
  ///
  /// Matches: #fff, #ffffff, #ffffffff, #FFF, #FFFFFF, #FFFFFFFF
  static final hexColor = RegExp(
    r'#([A-Fa-f0-9]{3}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})\b',
  );

  /// API key prefixes from common providers
  ///
  /// Used by:
  /// - SecurityService: Block auto-send of API keys
  static final apiKey = RegExp(
    r'(sk_live_|pk_live_|sk_test_|pk_test_|ghp_|gho_|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35})\w*',
  );

  /// Credit card pattern: 13-19 digits with optional spaces/dashes
  ///
  /// Used by:
  /// - SecurityService: Block auto-send of credit card numbers
  ///
  /// Matches: 4532148803436467, 4532-1488-0343-6467, 4532 1488 0343 6467
  static final creditCard = RegExp(
    r'\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{1,7}',
  );
}
