import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/device_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _token = 'phone-registration-token-that-another-account-still-holds';

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
      'is_anonymous': true,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
    },
  };
}

/// What production answers when a write collides with
/// devices_fcm_token_global_unique.
http.Response _tokenTaken(http.Request request) => http.Response(
  jsonEncode({
    'code': '23505',
    'message': 'duplicate key value violates unique constraint '
        '"devices_fcm_token_global_unique"',
  }),
  409,
  headers: {'content-type': 'application/json'},
  request: request,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SupabaseClient client;
  late DeviceService devices;
  late List<http.Request> requests;
  late bool claimSucceeds;

  setUp(() async {
    requests = [];
    claimSucceeds = true;
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = request.url.path;
        if (path == '/rest/v1/rpc/claim_fcm_token') {
          return http.Response(
            '$claimSucceeds',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (path == '/rest/v1/devices' && request.method == 'POST') {
          final row = jsonDecode(request.body) as Map<String, Object?>;
          if (row['fcm_token'] != null) return _tokenTaken(request);
          return http.Response(
            jsonEncode({'id': 'this-device'}),
            201,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (path == '/rest/v1/devices' && request.method == 'PATCH') {
          return _tokenTaken(request);
        }
        return http.Response('[]', 200, request: request);
      }),
    );
    await client.auth.recoverSession(jsonEncode(_session('guest')));
    devices = DeviceService(supabaseClient: client);
    await devices.initialize();
    requests.clear();
  });

  tearDown(() => client.dispose());

  Iterable<String> calls() =>
      requests.map((r) => '${r.method} ${r.url.path}');

  Map<String, Object?> claimParams() =>
      jsonDecode(
            requests
                .singleWhere((r) => r.url.path.endsWith('/claim_fcm_token'))
                .body,
          )
          as Map<String, Object?>;

  test('a token held by another account is claimed server-side', () async {
    await devices.registerCurrentDevice();
    requests.clear();

    await devices.updateFcmToken(_token);

    expect(claimParams(), {'p_device_id': 'this-device', 'p_token': _token});
    // The old client-side delete could only ever touch this account's rows.
    expect(calls(), isNot(contains('DELETE /rest/v1/devices')));
  });

  test(
    'registration still succeeds when the token is taken, then claims it',
    () async {
      expect(await devices.registerCurrentDevice(fcmToken: _token), isTrue);

      final upserts = requests
          .where((r) => r.method == 'POST' && r.url.path == '/rest/v1/devices')
          .map((r) => (jsonDecode(r.body) as Map)['fcm_token'])
          .toList();
      // First with the token, which collides; then without it, which lands.
      expect(upserts, [_token, null]);
      expect(claimParams(), {'p_device_id': 'this-device', 'p_token': _token});
    },
  );

  test('a refused claim does not throw', () async {
    claimSucceeds = false;
    await devices.registerCurrentDevice();

    await expectLater(devices.updateFcmToken(_token), completes);
  });
}
