import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/timeout_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, Object?> _session(String id) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': id, 'exp': expires})))
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$payload.signature',
    'refresh_token': 'refresh-$id',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expires,
    'user': {
      'id': id,
      'aud': 'authenticated',
      'role': 'authenticated',
      'email': '$id@example.com',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
    },
  };
}

void main() {
  const deadline = Duration(milliseconds: 100);

  test('a request that never hears back fails at the deadline', () async {
    final client = TimeoutHttpClient(
      inner: MockClient((_) => Completer<http.Response>().future),
      timeout: deadline,
    );
    await expectLater(
      client.get(Uri.parse('https://example.com/rest/v1/devices')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('an upload gets the longer deadline', () async {
    final client = TimeoutHttpClient(
      inner: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      }),
      timeout: deadline,
      uploadTimeout: const Duration(seconds: 5),
    );
    final big = List.filled(TimeoutHttpClient.uploadThresholdBytes + 1, 0);
    final response = await client.post(
      Uri.parse('https://example.com/storage/v1/object/x'),
      body: big,
    );
    expect(response.statusCode, 200);
  });

  // The failure seen on macOS after sleep: the token refresh went out on a
  // connection that had died, never heard back, and every request queued
  // behind it - the device list spun for ever until the app was restarted.
  group('a token refresh whose first attempt never answers', () {
    late int refreshes;
    http.Client inner() => MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        refreshes++;
        // The first attempt is the dead connection.
        if (refreshes == 1) return Completer<http.Response>().future;
      }
      return http.Response(jsonEncode(_session('me')), 200);
    });
    GoTrueClient auth(http.Client client) => GoTrueClient(
      url: 'https://example.com/auth/v1',
      autoRefreshToken: false,
      httpClient: client,
    );

    setUp(() => refreshes = 0);

    test('hangs without a deadline', () async {
      await expectLater(
        auth(
          inner(),
        ).setSession('refresh-me').timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
      expect(refreshes, 1);
    });

    test('recovers with one: the retry goes out and succeeds', () async {
      final response = await auth(
        TimeoutHttpClient(inner: inner(), timeout: deadline),
      ).setSession('refresh-me').timeout(const Duration(seconds: 10));

      expect(response.session?.user.id, 'me');
      expect(refreshes, 2);
    });
  });
}
