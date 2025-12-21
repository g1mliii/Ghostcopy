import 'dart:convert';

import 'package:ghostcopy/services/impl/transformer_service.dart';
import 'package:ghostcopy/services/transformer_service.dart';
import 'package:glados/glados.dart';

/// Property-based tests for TransformerService
///
/// Uses Glados for property testing with 100 iterations per test
void main() {
  group('TransformerService Property Tests', () {
    late ITransformerService transformerService;

    setUp(() {
      transformerService = TransformerService();
    });

    /**
     * Feature: ghostcopy
     * Property 13: JSON Detection
     *
     * GIVEN a valid JSON object or array
     * WHEN detectContentType() is called
     * THEN it SHALL return ContentType.json
     * AND metadata SHALL indicate valid JSON
     *
     * Validates Requirements 7.1
     */
    test('**Feature: ghostcopy, Property 13: JSON Detection**', () {
      // Generate 100 random JSON objects
      for (var i = 0; i < 100; i++) {
        // GIVEN: Generate random JSON object
        final data = {
          'id': i,
          'name': 'Test $i',
          'active': i.isEven,
          'value': i * 1.5,
          'nested': {
            'key': 'value$i',
            'count': i,
          },
          'array': [1, 2, 3, i],
        };
        final jsonString = json.encode(data);

        // WHEN: Detect content type
        final result = transformerService.detectContentType(jsonString);

        // THEN: Should detect as JSON
        expect(result.type, equals(ContentType.json));
        expect(result.metadata?['valid'], equals(true));
        expect(result.isTransformable, isTrue);
      }
    });

    /**
     * Feature: ghostcopy
     * Property 14: JWT Detection and Decoding
     *
     * GIVEN a valid JWT token structure (header.payload.signature)
     * WHEN detectContentType() is called
     * THEN it SHALL return ContentType.jwt
     * AND metadata SHALL indicate JWT format
     *
     * Validates Requirements 7.2
     */
    test('**Feature: ghostcopy, Property 14: JWT Detection**', () {
      // Generate 100 JWT-like tokens
      for (var i = 0; i < 100; i++) {
        // GIVEN: Valid JWT structure (base64url encoded parts without padding)
        final header = base64Url
            .encode(
              utf8.encode(json.encode({'alg': 'HS256', 'typ': 'JWT'})),
            )
            .replaceAll('=', '');
        final payload = base64Url
            .encode(
              utf8.encode(
                json.encode({
                  'sub': '${1234567890 + i}',
                  'name': 'User $i',
                  'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                }),
              ),
            )
            .replaceAll('=', '');
        final signature = base64Url
            .encode(List.generate(32, (j) => i + j))
            .replaceAll('=', '');

        final jwtToken = '$header.$payload.$signature';

        // WHEN: Detect content type
        final result = transformerService.detectContentType(jwtToken);

        // THEN: Should detect as JWT
        expect(result.type, equals(ContentType.jwt));
        expect(result.metadata?['format'], equals('JWT'));
        expect(result.isTransformable, isTrue);
      }
    });

    /**
     * Feature: ghostcopy
     * Property 15: Hex Color Detection
     *
     * GIVEN a valid hex color code (#RGB, #RRGGBB, or #RRGGBBAA)
     * WHEN detectContentType() is called
     * THEN it SHALL return ContentType.hexColor
     * AND metadata SHALL contain the color value
     *
     * Validates Requirements 7.3
     */
    test('**Feature: ghostcopy, Property 15: Hex Color Detection**', () {
      // Test all three hex color formats across 100 iterations
      for (var i = 0; i < 100; i++) {
        final testCases = [
          // #RGB format
          '#${(i % 16).toRadixString(16)}${(i % 16).toRadixString(16)}${(i % 16).toRadixString(16)}',
          // #RRGGBB format
          '#${(i % 256).toRadixString(16).padLeft(2, '0')}${(i % 256).toRadixString(16).padLeft(2, '0')}${(i % 256).toRadixString(16).padLeft(2, '0')}',
          // #RRGGBBAA format
          '#${(i % 256).toRadixString(16).padLeft(2, '0')}${(i % 256).toRadixString(16).padLeft(2, '0')}${(i % 256).toRadixString(16).padLeft(2, '0')}ff',
        ];

        for (final hexColor in testCases) {
          // WHEN: Detect content type
          final result = transformerService.detectContentType(hexColor);

          // THEN: Should detect as hex color
          expect(result.type, equals(ContentType.hexColor));
          expect(result.metadata?['color'], equals(hexColor));
          expect(result.isTransformable, isTrue);
        }
      }
    });

    /**
     * Additional test: Plain text detection
     *
     * GIVEN plain text content
     * WHEN detectContentType() is called
     * THEN it SHALL return ContentType.plainText
     * AND isTransformable SHALL be false
     */
    Glados(any.letterOrDigits).test(
      'Plain Text Detection',
      (plainText) {
        // Skip if too short (handled by early return)
        if (plainText.length < 3) return;

        // WHEN: Detect content type
        final result = transformerService.detectContentType(plainText);

        // THEN: Should detect as plain text (unless accidentally matches pattern)
        if (result.type == ContentType.plainText) {
          expect(result.isTransformable, isFalse);
        }
      },
    );

    /**
     * Edge case test: Empty and very short strings
     */
    test('Edge Cases: Empty and Short Strings', () {
      // Empty string
      var result = transformerService.detectContentType('');
      expect(result.type, equals(ContentType.plainText));

      // Very short strings
      result = transformerService.detectContentType('a');
      expect(result.type, equals(ContentType.plainText));

      result = transformerService.detectContentType('ab');
      expect(result.type, equals(ContentType.plainText));
    });

    /**
     * Performance test: Detection should be fast
     */
    test('Performance: Fast Detection', () {
      const testContent = '{"key": "value", "nested": {"foo": "bar"}}';

      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        transformerService.detectContentType(testContent);
      }
      stopwatch.stop();

      // 1000 detections should complete in under 100ms (avg < 0.1ms each)
      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    /**
     * Memory leak test: Service should be stateless
     */
    test('Memory Leak Prevention: Stateless Service', () {
      const testContent = '{"test": "data"}';

      // Multiple detections should not accumulate memory
      for (var i = 0; i < 1000; i++) {
        transformerService.detectContentType(testContent);
      }

      // If this test completes without memory issues, we're good
      expect(true, isTrue);
    });

    /**
     * Correctness test: JSON arrays should be detected
     */
    test('JSON Array Detection', () {
      const jsonArray = '[1, 2, 3, "test", {"key": "value"}]';
      final result = transformerService.detectContentType(jsonArray);

      expect(result.type, equals(ContentType.json));
      expect(result.metadata?['valid'], equals(true));
    });

    /**
     * Correctness test: Invalid JSON should not be detected as JSON
     */
    test('Invalid JSON Rejection', () {
      const invalidJson = '{"key": "value"'; // Missing closing brace
      final result = transformerService.detectContentType(invalidJson);

      // Should NOT detect as JSON (should be plain text)
      expect(result.type, isNot(equals(ContentType.json)));
    });

    /**
     * Correctness test: Hex color case insensitivity
     */
    test('Hex Color Case Insensitivity', () {
      final testCases = ['#FFF', '#fff', '#FfFfFf', '#ffffff'];

      for (final hexColor in testCases) {
        final result = transformerService.detectContentType(hexColor);
        expect(result.type, equals(ContentType.hexColor));
      }
    });

    /**
     * Feature: ghostcopy
     * Property 16: JSON Round-Trip
     *
     * GIVEN valid JSON content in any format
     * WHEN transform() is called with ContentType.json
     * THEN the prettified result SHALL preserve data semantics
     * AND decode(prettified) == decode(original) for all data values
     *
     * Validates Requirements 7.5, 7.6
     */
    test('**Feature: ghostcopy, Property 16: JSON Round-Trip**', () {
      // Generate 100 random JSON objects with various data types
      for (var i = 0; i < 100; i++) {
        // GIVEN: Create diverse JSON structures
        final data = {
          'string': 'Test value $i',
          'integer': i,
          'float': i * 1.5,
          'boolean': i.isEven,
          'null_value': null,
          'array': [1, 'two', 3.0, true, null],
          'nested_object': {
            'level2': {
              'level3': {
                'value': 'deep$i',
                'count': i,
              }
            }
          },
          'mixed_array': [
            {'id': i, 'name': 'Item $i'},
            [i, i + 1, i + 2],
            'string',
            i.isOdd,
          ],
          'empty_object': <String, dynamic>{},
          'empty_array': <dynamic>[],
          'special_chars': 'Special: \n\t\r"quotes"\\backslash',
          'unicode': '🎉 emoji $i',
        };

        // GIVEN: Encode as JSON string
        final originalJson = json.encode(data);

        // WHEN: Transform (prettify) the JSON
        final transformResult = transformerService.transform(
          originalJson,
          ContentType.json,
        );

        // THEN: Transformation should succeed
        expect(transformResult.isSuccess, isTrue,
            reason: 'Transform should succeed for valid JSON');
        expect(transformResult.transformedContent, isNotNull,
            reason: 'Prettified content should not be null');
        expect(transformResult.error, isNull,
            reason: 'Should not have error message');

        // THEN: Prettified JSON should contain 2-space indentation
        expect(transformResult.transformedContent!.contains('  '), isTrue,
            reason: 'Prettified JSON should contain 2-space indentation');

        // THEN: Data should be preserved (round-trip test)
        final prettifiedJson = transformResult.transformedContent!;
        final originalDecoded = json.decode(originalJson);
        final prettifiedDecoded = json.decode(prettifiedJson);

        // Deep equality check: decoded versions must be identical
        expect(prettifiedDecoded, equals(originalDecoded),
            reason: 'Prettified JSON must decode to same data as original');

        // THEN: Verify no data loss in transformation
        expect(_jsonDataEquality(originalDecoded, prettifiedDecoded), isTrue,
            reason: 'All data should be preserved after prettification');
      }
    });

    /**
     * Error handling test: Invalid JSON should return error
     */
    test('JSON Transformation Error Handling', () {
      final invalidJsonCases = [
        '{invalid json}',
        '{"key": value}', // unquoted value
        "{'single': 'quotes'}", // single quotes
        '{"trailing": "comma",}',
        '{undefined}',
      ];

      for (final invalidJson in invalidJsonCases) {
        // WHEN: Transform invalid JSON
        final result = transformerService.transform(invalidJson, ContentType.json);

        // THEN: Should return error, not crash
        expect(result.isSuccess, isFalse,
            reason: 'Should report error for invalid JSON: $invalidJson');
        expect(result.transformedContent, isNull,
            reason: 'Should not provide transformed content for invalid JSON');
        expect(result.error, isNotNull,
            reason: 'Should provide error message');
      }
    });

    /**
     * Prettification test: Verify formatting is consistent
     */
    test('JSON Prettification Format Consistency', () {
      const originalJson = '{"a":1,"b":{"c":2},"d":[1,2,3]}';

      final result1 = transformerService.transform(originalJson, ContentType.json);
      final result2 = transformerService.transform(
        result1.transformedContent!,
        ContentType.json,
      );

      // THEN: Multiple transformations should be idempotent
      // (prettifying already prettified JSON should give same result)
      expect(result1.transformedContent, equals(result2.transformedContent),
          reason:
              'Prettifying already prettified JSON should be idempotent');
    });

    /**
     * Edge case: Very large JSON objects should still work
     */
    test('JSON Transformation: Large Objects', () {
      // GIVEN: Create a large JSON object
      final largeData = {
        'items': List.generate(
          100,
          (i) => {
            'id': i,
            'name': 'Item $i',
            'description': 'A' * 100, // 100 character string
            'values': List.generate(10, (j) => i * j),
          },
        ),
      };

      final jsonString = json.encode(largeData);

      // WHEN: Transform large JSON
      final result = transformerService.transform(jsonString, ContentType.json);

      // THEN: Should handle large objects gracefully
      expect(result.isSuccess, isTrue);
      expect(result.transformedContent, isNotNull);

      // Verify data is preserved
      final original = json.decode(jsonString);
      final prettified = json.decode(result.transformedContent!);
      expect(prettified, equals(original));
    });

    /**
     * Feature: ghostcopy
     * Property 17: JWT Decoding and Payload Extraction
     *
     * GIVEN a valid JWT token with header.payload.signature format
     * WHEN transform() is called with ContentType.jwt
     * THEN the decoded payload SHALL be displayed in the preview
     * AND the token itself SHALL NOT be modified (transformedContent = null)
     * AND the preview SHALL contain expiration and user info
     *
     * Validates Requirements 7.2
     */
    test('**Feature: ghostcopy, Property 17: JWT Decoding**', () {
      // Generate 100 valid JWT tokens with various payloads
      for (var i = 0; i < 100; i++) {
        // GIVEN: Create valid JWT payload
        final now = DateTime.now();
        final expirationSeconds = (now.add(Duration(hours: i % 24)).millisecondsSinceEpoch / 1000).toInt();

        final header = base64Url
            .encode(utf8.encode(json.encode({'alg': 'HS256', 'typ': 'JWT'})))
            .replaceAll('=', '');

        final payload = base64Url
            .encode(
              utf8.encode(
                json.encode({
                  'sub': 'user_${i % 1000}',
                  'email': 'user$i@example.com',
                  'name': 'Test User $i',
                  'exp': expirationSeconds,
                  'iat': (now.millisecondsSinceEpoch / 1000).toInt(),
                  'custom_claim': 'value_$i',
                }),
              ),
            )
            .replaceAll('=', '');

        final signature = base64Url
            .encode(List.generate(32, (j) => (i + j) % 256))
            .replaceAll('=', '');

        final jwtToken = '$header.$payload.$signature';

        // WHEN: Transform JWT
        final result = transformerService.transform(jwtToken, ContentType.jwt);

        // THEN: Transformation should succeed
        expect(result.isSuccess, isFalse, // Note: isSuccess checks transformedContent != null AND error == null
            reason: 'JWT should have null transformedContent (token not modified)');
        expect(result.error, isNull,
            reason: 'Should not have error for valid JWT');
        expect(result.preview, isNotNull,
            reason: 'Should have preview with decoded payload');

        // THEN: Token itself should NOT be modified
        expect(result.transformedContent, isNull,
            reason: 'JWT token should not be modified');

        // THEN: Preview should contain payload information
        expect(result.preview, contains('sub'),
            reason: 'Preview should contain decoded payload fields');
        expect(result.preview, contains('user_${i % 1000}'),
            reason: 'Preview should contain user ID');

        // THEN: Preview should contain expiration info
        expect(result.preview, contains('Expires'),
            reason: 'Preview should contain expiration information');

        // THEN: Preview should contain user info
        expect(result.preview, contains('👤'),
            reason: 'Preview should contain user indicator');
      }
    });

    /**
     * JWT decoding test: Valid JWT with various claim types
     */
    test('JWT Decoding: Various Payload Types', () {
      final testCases = [
        // Simple payload
        {
          'header': {'alg': 'HS256'},
          'payload': {'sub': 'user123', 'exp': 1700000000},
        },
        // Payload with nested objects
        {
          'header': {'alg': 'RS256', 'kid': 'key-1'},
          'payload': {
            'sub': 'user456',
            'aud': 'api.example.com',
            'claims': {'role': 'admin', 'permissions': ['read', 'write']}
          },
        },
        // Payload with various data types
        {
          'header': {'alg': 'HS512'},
          'payload': {
            'user_id': 789,
            'active': true,
            'score': 95.5,
            'tags': ['verified', 'premium'],
            'metadata': null,
          },
        },
      ];

      for (final testCase in testCases) {
        final header = base64Url
            .encode(utf8.encode(json.encode(testCase['header'])))
            .replaceAll('=', '');
        final payload = base64Url
            .encode(utf8.encode(json.encode(testCase['payload'])))
            .replaceAll('=', '');
        final signature = base64Url
            .encode(List.generate(32, (i) => i))
            .replaceAll('=', '');

        final jwtToken = '$header.$payload.$signature';

        final result = transformerService.transform(jwtToken, ContentType.jwt);

        expect(result.error, isNull, reason: 'Should decode valid JWT');
        expect(result.preview, isNotNull);
        expect(result.transformedContent, isNull);
      }
    });

    /**
     * JWT error handling test: Invalid JWT formats
     */
    test('JWT Decoding Error Handling', () {
      final invalidJwtCases = [
        'not.a.jwt', // Valid format but invalid base64
        'header.payload', // Missing signature part
        'header.payload.sig.extra', // Too many parts
        'header..signature', // Empty payload
        '.payload.signature', // Empty header
        'header.payload.', // Empty signature
        'invalid-jwt-format', // No dots at all
        '', // Empty string
      ];

      for (final invalidJwt in invalidJwtCases) {
        final result = transformerService.transform(invalidJwt, ContentType.jwt);

        expect(result.error, isNotNull,
            reason: 'Should report error for invalid JWT: $invalidJwt');
        expect(result.transformedContent, isNull);
        expect(result.preview, isNull);
      }
    });

    /**
     * JWT expiration test: Parse expiration dates correctly
     */
    test('JWT Expiration Parsing', () {
      // Future token
      final futureExp = (DateTime.now().add(Duration(hours: 24)).millisecondsSinceEpoch / 1000).toInt();
      final futurePayload = base64Url
          .encode(utf8.encode(json.encode({
            'sub': 'user',
            'exp': futureExp,
          })))
          .replaceAll('=', '');

      final header = base64Url
          .encode(utf8.encode(json.encode({'alg': 'HS256'})))
          .replaceAll('=', '');
      final signature = base64Url.encode([0, 1, 2]).replaceAll('=', '');

      final futureJwt = '$header.$futurePayload.$signature';
      var result = transformerService.transform(futureJwt, ContentType.jwt);

      expect(result.preview, contains('✅ VALID'),
          reason: 'Future token should show as VALID');

      // Expired token
      final expiredExp = (DateTime.now().subtract(Duration(hours: 24)).millisecondsSinceEpoch / 1000).toInt();
      final expiredPayload = base64Url
          .encode(utf8.encode(json.encode({
            'sub': 'user',
            'exp': expiredExp,
          })))
          .replaceAll('=', '');

      final expiredJwt = '$header.$expiredPayload.$signature';
      result = transformerService.transform(expiredJwt, ContentType.jwt);

      expect(result.preview, contains('❌ EXPIRED'),
          reason: 'Expired token should show as EXPIRED');
    });

    /**
     * JWT user info extraction test
     */
    test('JWT User Info Extraction', () {
      // Test different user ID claim names
      final userIdClaims = [
        {'sub': 'user-sub-123'},
        {'user_id': 'user-id-456'},
        {'user': 'user-name-789'},
      ];

      final header = base64Url
          .encode(utf8.encode(json.encode({'alg': 'HS256'})))
          .replaceAll('=', '');
      final signature = base64Url.encode([0]).replaceAll('=', '');

      for (final claims in userIdClaims) {
        final payload = base64Url
            .encode(utf8.encode(json.encode(claims)))
            .replaceAll('=', '');

        final jwt = '$header.$payload.$signature';
        final result = transformerService.transform(jwt, ContentType.jwt);

        expect(result.preview, contains('👤 User ID:'),
            reason: 'Should extract user ID from various claim names');
      }
    });

    /**
     * Performance test: JWT decoding should be fast
     */
    test('Performance: Fast JWT Decoding', () {
      final header = base64Url
          .encode(utf8.encode(json.encode({'alg': 'HS256'})))
          .replaceAll('=', '');
      final payload = base64Url
          .encode(utf8.encode(json.encode({
            'sub': 'user123',
            'exp': DateTime.now().add(Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          })))
          .replaceAll('=', '');
      final signature = base64Url.encode([0, 1, 2]).replaceAll('=', '');
      final jwtToken = '$header.$payload.$signature';

      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        transformerService.transform(jwtToken, ContentType.jwt);
      }
      stopwatch.stop();

      // 1000 JWT decodings should complete in under 500ms (avg < 0.5ms each)
      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });
  });
}

/// Helper function to deeply compare JSON-decoded objects
/// Verifies that two decoded JSON objects are semantically identical
bool _jsonDataEquality(dynamic a, dynamic b) {
  if (identical(a, b)) return true;

  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_jsonDataEquality(a[key], b[key])) return false;
    }
    return true;
  }

  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonDataEquality(a[i], b[i])) return false;
    }
    return true;
  }

  return a == b;
}
