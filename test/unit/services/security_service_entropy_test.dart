import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/security_service.dart';
import 'package:ghostcopy/services/security_service.dart';

/// Regression tests for high-entropy detection.
///
/// The original check counted character CLASSES and treated any printable
/// non-alphanumeric as "special", so `.` `/` `:` `-` `_` all qualified. Every
/// URL with a digit and a capital in it was therefore reported as a secret and
/// withheld from auto-send.
void main() {
  final service = SecurityService();

  bool flagged(String content) =>
      service.detectSensitiveData(content).isSensitive;

  group('ordinary content is not sensitive', () {
    const benign = <String>[
      'https://example.com/Path123',
      'https://docs.flutter.dev/cookbook/Testing1',
      'com.ghostcopy.app.Widget2',
      '/usr/local/share/Thing123/bin',
      r'C:\Users\Someone\Documents\Report2024.txt',
      'CamelCaseIdentifier123',
      'order-number-4815162342-confirmed',
    ];

    for (final content in benign) {
      test(content, () => expect(flagged(content), isFalse));
    }
  });

  group('actual secrets are still caught', () {
    test('random base64-ish key', () {
      expect(flagged('kJ8xQ2mVn4PzR7tYw1LbA9sCfG3hD6eU'), isTrue);
    });

    test('api key prefix', () {
      expect(flagged('sk_live_51HxYzAbCdEfGhIjKlMnOp'), isTrue);
    });

    test('jwt', () {
      expect(
        flagged(
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
        ),
        isTrue,
      );
    });

    test('credit card', () {
      expect(flagged('card 4111111111111111 exp'), isTrue);
    });

    test('credit card after a non-card digit run', () {
      // firstMatch() used to stop at the leading order number and miss this.
      expect(flagged('order 1234567890123 card 4532-0151-1283-0366'), isTrue);
    });
  });

  test('detection type is reported', () {
    expect(
      service.detectSensitiveData('card 4111111111111111 exp').type,
      SensitiveDataType.creditCard,
    );
  });
}
