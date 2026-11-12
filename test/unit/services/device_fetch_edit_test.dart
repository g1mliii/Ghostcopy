import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/device.dart';
import 'package:ghostcopy/services/impl/device_service.dart';
import 'package:ghostcopy/services/saved_device_list.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, Object?> _session() => {
  'access_token': 'e30.e30.signature',
  'refresh_token': 'refresh',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': 'me',
    'aud': 'authenticated',
    'role': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
  },
};

Map<String, Object?> _row(String id) => {
  'id': id,
  'user_id': 'me',
  'device_type': 'windows',
  'device_name': 'PC $id',
  'last_active': '2026-01-01T00:00:00Z',
  'created_at': '2026-01-01T00:00:00Z',
};

/// A rename or removal the server accepts while a device fetch is out: the
/// fetch's answer may predate it, and must not undo it - in the cache, in
/// what is returned, or in the list saved for the next launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an edit made during a fetch is applied to its answer, not lost',
    () async {
      SharedPreferences.setMockInitialValues({});
      final answer = Completer<List<Map<String, Object?>>>();
      final client = SupabaseClient(
        'https://example.com',
        'anon-key',
        httpClient: MockClient((request) async {
          http.Response respond(Object body) => http.Response(
            jsonEncode(body),
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
          if (request.url.path != '/rest/v1/devices') return respond([]);
          return switch (request.method) {
            'GET' => respond(await answer.future),
            _ => respond([]),
          };
        }),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session()));
      final devices = DeviceService(
        supabaseClient: client,
        deviceTypeProvider: () => 'windows',
        deviceNameProvider: () => 'PC a',
      );
      await devices.initialize();

      // The list saved by an earlier launch.
      await SavedDeviceList.save('me', [
        for (final id in ['a', 'b']) Device.fromJson(_row(id)),
      ], generation: SavedDeviceList.generation);

      final fetching = devices.fetchUserDevices();
      // b is removed while the fetch is out...
      expect(await devices.removeDevice('b'), isTrue);
      // ...and the fetch answers from before that, with c, added elsewhere.
      answer.complete([_row('a'), _row('b'), _row('c')]);

      final fetched = await fetching;
      expect(fetched!.map((d) => d.id), ['a', 'c']);

      final saved = await SavedDeviceList.load('me');
      expect(saved.map((d) => d.id), ['a', 'c']);
    },
  );
}
