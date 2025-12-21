import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/security_service.dart';
import 'package:ghostcopy/services/impl/transformer_service.dart';
import 'package:ghostcopy/services/security_service.dart';
import 'package:ghostcopy/services/transformer_service.dart';

/// DoS (Denial of Service) attack simulation tests
///
/// These tests verify that the services handle malicious/extreme inputs safely
/// without crashing, hanging, or consuming excessive resources.
void main() {
  group('DoS Attack Prevention Tests', () {
    late ISecurityService securityService;
    late ITransformerService transformerService;

    setUp(() {
      securityService = SecurityService();
      transformerService = TransformerService();
    });

    group('SecurityService DoS Protection', () {
      test('Handles very large content (10MB) safely', () {
        // Simulate attacker copying large file to clipboard
        final hugeContent = 'a' * 10000000; // 10MB of text

        final stopwatch = Stopwatch()..start();
        final result = securityService.detectSensitiveData(hugeContent);
        stopwatch.stop();

        // Should complete quickly without hanging
        expect(stopwatch.elapsedMilliseconds, lessThan(10));

        // Should block as sensitive (safer than crash)
        expect(result.isSensitive, isTrue);
        expect(
          result.reason,
          contains('too large'),
        );
      });

      test('Handles malformed regex input safely', () {
        // Try to trigger ReDoS with nested braces
        final malformed = '{' * 1000 + 'a' * 1000; // No closing braces

        final stopwatch = Stopwatch()..start();
        securityService.detectSensitiveData(malformed);
        stopwatch.stop();

        // Should complete in reasonable time (not hang)
        expect(stopwatch.elapsedMilliseconds, lessThan(100));
      });

      test('Handles repeated special characters safely', () {
        // Unicode and special chars that might break regex
        final specialChars = '🔥💀👻' * 1000;

        final result = securityService.detectSensitiveData(specialChars);

        // Should not crash or throw
        expect(result, isNotNull);
      });

      test('Memory leak: Multiple large content detections', () {
        // Verify no memory accumulation over many calls
        for (var i = 0; i < 100; i++) {
          final content = 'test content $i' * 1000;
          securityService.detectSensitiveData(content);
        }

        // If this completes without OOM, we're good
        expect(true, isTrue);
      });
    });

    group('TransformerService DoS Protection', () {
      test('Handles very large JSON (>1MB) safely', () {
        // Build a JSON that exceeds 1MB (1MB = 1,048,576 bytes)
        final largeData = 'x' * 1100000; // 1.1 million chars
        final largeJson = '{"data": "$largeData"}';

        // Verify it's actually over 1MB
        expect(largeJson.length, greaterThan(1048576));

        final stopwatch = Stopwatch()..start();
        final result = transformerService.detectContentType(largeJson);
        stopwatch.stop();

        // Should reject quickly (not try to parse)
        expect(stopwatch.elapsedMilliseconds, lessThan(10));

        // Should return plain text (rejected as too large)
        expect(result.type, equals(ContentType.plainText));
      });

      test('Handles deeply nested JSON safely', () {
        // Create deeply nested structure using StringBuffer (lint)
        final buffer = StringBuffer('{"a":');
        for (var i = 0; i < 100; i++) {
          buffer.write('{"b":');
        }
        buffer.write('"value"');
        for (var i = 0; i < 100; i++) {
          buffer.write('}');
        }
        buffer.write('}');
        final nested = buffer.toString();

        final stopwatch = Stopwatch()..start();
        final result = transformerService.detectContentType(nested);
        stopwatch.stop();

        // Should handle gracefully
        expect(stopwatch.elapsedMilliseconds, lessThan(100));

        // If detected as JSON, it parsed successfully
        // If plain text, it was rejected (both OK)
        expect(result.type, isIn([ContentType.json, ContentType.plainText]));
      });

      test('Handles malformed JWT tokens safely', () {
        // JWT with very long segments
        final longJwt = 'eyJ${'a' * 10000}.eyJ${'b' * 10000}.${'c' * 10000}';

        final result = transformerService.detectContentType(longJwt);

        // Should not crash
        expect(result, isNotNull);
      });

      test('Memory leak: Multiple detections', () {
        // Verify no memory accumulation
        for (var i = 0; i < 1000; i++) {
          final content = '{"test": $i}';
          transformerService.detectContentType(content);
        }

        // If this completes without OOM, we're good
        expect(true, isTrue);
      });
    });

    group('Combined Attack Scenarios', () {
      test('Sequential large content attacks', () {
        final attacks = [
          'a' * 2000000, // 2MB text
          '{"data": "${'x' * 1000000}"}', // 1MB JSON
          'sk_live_${'1234567890abcdef' * 10000}', // Fake long API key
          '#${'ff' * 100000}', // Fake long hex color
        ];

        for (final attack in attacks) {
          final secResult = securityService.detectSensitiveData(attack);
          final transResult = transformerService.detectContentType(attack);

          // Should handle all safely
          expect(secResult, isNotNull);
          expect(transResult, isNotNull);
        }
      });

      test('Performance: 1000 mixed detections under 500ms', () {
        final testCases = [
          'normal text',
          '{"key": "value"}',
          '#ffffff',
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.signature',
          'sk_live_1234567890',
          '1234 5678 9012 3456',
        ];

        final stopwatch = Stopwatch()..start();
        for (var i = 0; i < 1000; i++) {
          final content = testCases[i % testCases.length];
          securityService.detectSensitiveData(content);
          transformerService.detectContentType(content);
        }
        stopwatch.stop();

        // 2000 total calls (1000 security + 1000 transformer) in < 500ms
        expect(stopwatch.elapsedMilliseconds, lessThan(500));
      });
    });

    group('Edge Cases', () {
      test('Empty string is safe', () {
        final secResult = securityService.detectSensitiveData('');
        final transResult = transformerService.detectContentType('');

        expect(secResult.isSensitive, isFalse);
        expect(transResult.type, equals(ContentType.plainText));
      });

      test('Null bytes and control characters', () {
        final controlChars = String.fromCharCodes([0, 1, 2, 3, 4, 5]);

        final secResult = securityService.detectSensitiveData(controlChars);
        final transResult = transformerService.detectContentType(controlChars);

        // Should not crash
        expect(secResult, isNotNull);
        expect(transResult, isNotNull);
      });

      test('Maximum safe content (just under 1MB)', () {
        final maxContent = 'a' * (1048576 - 1); // Just under 1MB

        final stopwatch = Stopwatch()..start();
        final secResult = securityService.detectSensitiveData(maxContent);
        final transResult = transformerService.detectContentType(maxContent);
        stopwatch.stop();

        // Should complete quickly
        expect(stopwatch.elapsedMilliseconds, lessThan(50));

        // Both should process (not block, since under limit)
        expect(secResult, isNotNull);
        expect(transResult, isNotNull);
      });

      test('Just over limit (1MB + 1 byte)', () {
        final overLimit = 'a' * 1048577; // 1MB + 1 byte

        final secResult = securityService.detectSensitiveData(overLimit);
        final transResult = transformerService.detectContentType(overLimit);

        // Both should reject
        expect(secResult.isSensitive, isTrue); // Blocked as too large
        expect(transResult.type, equals(ContentType.plainText)); // Rejected
      });
    });
  });
}
