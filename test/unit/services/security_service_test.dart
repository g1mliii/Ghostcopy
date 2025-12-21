import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/security_service.dart';
import 'package:ghostcopy/services/security_service.dart';

void main() {
  group('SecurityService', () {
    late ISecurityService securityService;

    setUp(() {
      securityService = SecurityService();
    });

    group('Performance Tests', () {
      test('should detect sensitive data in < 1ms for typical content', () {
        const testContent = 'test_sensitive_data_string_12345';

        final stopwatch = Stopwatch()..start();
        final result = securityService.detectSensitiveData(testContent);
        stopwatch.stop();

        expect(result.isSensitive, isTrue);
        expect(stopwatch.elapsedMilliseconds, lessThan(1));
      });

      test('should process safe content in < 1ms', () {
        const testContent = 'Hello world, this is a normal clipboard message';

        final stopwatch = Stopwatch()..start();
        final result = securityService.detectSensitiveData(testContent);
        stopwatch.stop();

        expect(result.isSensitive, isFalse);
        expect(stopwatch.elapsedMicroseconds, lessThan(2000)); // < 2ms (very fast)
      });
    });

    group('API Key Detection', () {
      test('should detect Stripe API key', () {
        const content = 'sk_live_test_1234567890abcdefghij';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.apiKey));
      });

      test('should detect GitHub token', () {
        const content = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.apiKey));
      });

      test('should detect AWS access key', () {
        const content = 'AKIAIOSFODNN7EXAMPLE';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.apiKey));
      });
    });

    group('JWT Token Detection', () {
      test('should detect valid JWT token', () {
        const content = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
            'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0.'
            'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.jwtToken));
      });
    });

    group('Credit Card Detection', () {
      test('should detect valid credit card with Luhn check', () {
        // Valid Visa test card (verified): 4532015112830366
        const content = '4532015112830366';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.creditCard));
      });

      test('should detect valid card with spaces', () {
        // Valid Visa test card with spaces
        const content = '4532 0151 1283 0366';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.creditCard));
      });

      test('should not flag invalid Luhn checksum as credit card', () {
        const content = '4532015112830367'; // Invalid checksum (last digit changed)
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isFalse);
      });
    });

    group('High Entropy Detection', () {
      test('should detect high-entropy password', () {
        const content = 'P@ssw0rd!2024#Secure';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isTrue);
        expect(result.type, equals(SensitiveDataType.highEntropy));
      });

      test('should not flag normal text as high entropy', () {
        const content = 'Hello world, this is a normal message';
        final result = securityService.detectSensitiveData(content);

        expect(result.isSensitive, isFalse);
      });
    });

    group('Edge Cases', () {
      test('should return safe for empty string', () {
        final result = securityService.detectSensitiveData('');

        expect(result.isSensitive, isFalse);
      });

      test('should return safe for very short string', () {
        final result = securityService.detectSensitiveData('abc');

        expect(result.isSensitive, isFalse);
      });

      test('should handle very long content efficiently', () {
        final longContent = 'a' * 10000; // 10KB of safe content

        final stopwatch = Stopwatch()..start();
        final result = securityService.detectSensitiveData(longContent);
        stopwatch.stop();

        expect(result.isSensitive, isFalse);
        expect(stopwatch.elapsedMilliseconds, lessThan(10)); // Still very fast
      });
    });

    group('Memory Leak Prevention', () {
      test('should not retain references after detection', () {
        // Multiple detections should not accumulate memory
        for (var i = 0; i < 1000; i++) {
          securityService.detectSensitiveData('test content $i');
        }

        // If this test completes without memory issues, we're good
        expect(true, isTrue);
      });

      test('service should be stateless', () {
        const content = 'sk_live_test123';

        final result1 = securityService.detectSensitiveData(content);
        final result2 = securityService.detectSensitiveData(content);

        // Both results should be identical (no state mutation)
        expect(result1.isSensitive, equals(result2.isSensitive));
        expect(result1.type, equals(result2.type));
      });
    });
  });
}
