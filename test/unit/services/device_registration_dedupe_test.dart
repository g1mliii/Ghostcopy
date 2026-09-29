import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/device_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _token = 'a-push-token-long-enough-to-be-a-real-fcm-registration';

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
      'email': '',
      'created_at': '2026-01-01T00:00:00Z',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late DeviceService devices;
  late List<String> calls;

  setUp(() async {
    calls = [];
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      httpClient: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        // Slow enough that the second call lands while the first runs.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (request.url.path == '/rest/v1/devices' &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode({'id': 'this-device'}),
            201,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response('[]', 200, request: request);
      }),
    );
    await client.auth.recoverSession(jsonEncode(_session('me')));
    devices = DeviceService(supabaseClient: client);
    await devices.initialize();
    calls.clear();
  });

  tearDown(() => client.dispose());

  int count(String call) => calls.where((c) => c == call).length;

  // The API logs showed two DELETEs and two upserts on devices within the
  // same second on every launch.
  test('simultaneous identical registrations share one write', () async {
    final results = await Future.wait([
      devices.registerCurrentDevice(fcmToken: _token),
      devices.registerCurrentDevice(fcmToken: _token),
      devices.registerCurrentDevice(fcmToken: _token),
    ]);

    expect(results, [true, true, true]);
    expect(count('DELETE /rest/v1/devices'), 1);
    expect(count('POST /rest/v1/devices'), 1);
  });

  test('a different token still registers on its own', () async {
    await Future.wait([
      devices.registerCurrentDevice(fcmToken: _token),
      devices.registerCurrentDevice(),
    ]);

    expect(count('POST /rest/v1/devices'), 2);
  });

  test('a registration after the last one finished runs again', () async {
    await devices.registerCurrentDevice(fcmToken: _token);
    await devices.registerCurrentDevice(fcmToken: _token);

    expect(count('POST /rest/v1/devices'), 2);
  });
}
