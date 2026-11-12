import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/device_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentName = 'Alice’s iPhone · 1A2B3C4D';
const _oldName = 'iPhone · 1A2B3C4D';
const _token = 'existing-push-token-long-enough-for-the-claim-rpc';

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

Map<String, Object?> _row(
  String id,
  String name, {
  String user = 'me',
  String type = 'ios',
  String? token,
}) => {
  'id': id,
  'user_id': user,
  'device_type': type,
  'device_name': name,
  'fcm_token': token,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late DeviceService devices;
  late List<Map<String, Object?>> rows;
  late List<http.Request> requests;
  late bool failLookup;
  late bool failRename;
  late bool failUpsert;
  late bool claimSucceeds;
  late String deviceType;
  late String deviceName;

  setUp(() async {
    rows = [_row('original', _oldName, token: _token)];
    requests = [];
    failLookup = false;
    failRename = false;
    failUpsert = false;
    claimSucceeds = true;
    deviceType = 'ios';
    deviceName = _currentName;
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        http.Response respond(Object body, [int status = 200]) => http.Response(
          jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
        if (request.url.path == '/rest/v1/rpc/claim_fcm_token') {
          final params = jsonDecode(request.body) as Map<String, Object?>;
          if (claimSucceeds) {
            for (final row in rows) {
              if (row['fcm_token'] == params['p_token']) {
                row['fcm_token'] = null;
              }
            }
            rows.singleWhere(
              (row) => row['id'] == params['p_device_id'],
            )['fcm_token'] = params['p_token'];
          }
          return respond(claimSucceeds);
        }
        if (request.url.path != '/rest/v1/devices') return respond([]);

        bool matches(Map<String, Object?> row) {
          for (final filter in request.url.queryParameters.entries) {
            if (filter.key == 'select' || filter.key == 'on_conflict') continue;
            final value = row[filter.key]?.toString();
            final condition = filter.value;
            if (condition.startsWith('eq.') &&
                value != condition.substring(3)) {
              return false;
            }
            if (condition.startsWith('neq.') &&
                value == condition.substring(4)) {
              return false;
            }
            if (condition.startsWith('like.') &&
                (value == null ||
                    !value.endsWith(
                      condition.substring(5).replaceAll('%', ''),
                    ))) {
              return false;
            }
            if (condition.startsWith('in.(') &&
                !condition
                    .substring(4, condition.length - 1)
                    .split(',')
                    .map((id) => id.replaceAll('"', ''))
                    .contains(value)) {
              return false;
            }
          }
          return true;
        }

        final selected = rows.where(matches).toList();
        if ((request.method == 'GET' && failLookup) ||
            (request.method == 'PATCH' && failRename) ||
            (request.method == 'POST' && failUpsert)) {
          return respond({'code': '42501', 'message': 'write refused'}, 403);
        }
        switch (request.method) {
          case 'GET':
            return respond(selected);
          case 'PATCH':
            final values = jsonDecode(request.body) as Map<String, Object?>;
            final token = values['fcm_token'];
            if (token != null &&
                rows.any(
                  (row) => row['fcm_token'] == token && !selected.contains(row),
                )) {
              return respond({
                'code': '23505',
                'message': 'token already claimed',
              }, 409);
            }
            for (final row in selected) {
              row.addAll(values);
            }
            return respond(
              request.headers['accept']?.contains('object') ?? false
                  ? selected.single
                  : selected,
            );
          case 'DELETE':
            rows.removeWhere(matches);
            return respond([]);
          case 'POST':
            final values = jsonDecode(request.body) as Map<String, Object?>;
            final existing = rows.where(
              (row) =>
                  row['user_id'] == values['user_id'] &&
                  row['device_type'] == values['device_type'] &&
                  row['device_name'] == values['device_name'],
            );
            final row = existing.isEmpty
                ? <String, Object?>{'id': 'new-${rows.length}'}
                : existing.single;
            if (existing.isEmpty) rows.add(row);
            row.addAll(values);
            return respond({
              'id': row['id'],
              'fcm_token': row['fcm_token'],
            }, 201);
          default:
            throw Exception('Unexpected device request: ${request.method}');
        }
      }),
    );
    await client.auth.recoverSession(jsonEncode(_session()));
    devices = DeviceService(
      supabaseClient: client,
      deviceTypeProvider: () => deviceType,
      deviceNameProvider: () => deviceName,
    );
    await devices.initialize();
    requests.clear();
  });

  tearDown(() => client.dispose());

  test(
    'tokenless upgrade keeps the original row ID and stored token',
    () async {
      expect(await devices.registerCurrentDevice(), isTrue);

      expect(rows, hasLength(1));
      expect(rows.single['id'], 'original');
      expect(rows.single['device_name'], _currentName);
      expect(rows.single['fcm_token'], _token);
      expect(devices.getCurrentDeviceId(), 'original');

      expect(await devices.registerCurrentDevice(), isTrue);
      expect(rows, hasLength(1));
      expect(devices.getCurrentDeviceId(), 'original');
    },
  );

  test(
    'migration without any stored or supplied token reuses the row',
    () async {
      rows.single['fcm_token'] = null;
      expect(await devices.registerCurrentDevice(fcmToken: ''), isTrue);
      expect(rows, hasLength(1));
      expect(rows.single['id'], 'original');
      expect(rows.single['device_name'], _currentName);
      expect(rows.single['fcm_token'], isNull);
    },
  );

  test(
    'failed token transfer retains the stale token row and retries',
    () async {
      rows.add(_row('current', _currentName));
      claimSucceeds = false;
      expect(await devices.registerCurrentDevice(), isFalse);
      expect(rows, hasLength(2));
      expect(rows.first['fcm_token'], _token);
      expect(rows.last['fcm_token'], isNull);

      claimSucceeds = true;
      expect(await devices.registerCurrentDevice(), isTrue);
      expect(rows, hasLength(1));
      expect(rows.single['fcm_token'], _token);
    },
  );

  test(
    'a current row token is kept instead of replaced with a stale one',
    () async {
      rows.add(_row('current', _currentName, token: 'current-token'));
      expect(await devices.registerCurrentDevice(), isTrue);
      expect(rows, hasLength(1));
      expect(rows.single['fcm_token'], 'current-token');
    },
  );

  test('migration with a token preserves the original row ID', () async {
    expect(await devices.registerCurrentDevice(fcmToken: _token), isTrue);
    expect(rows, hasLength(1));
    expect(devices.getCurrentDeviceId(), 'original');
    expect(rows.single['fcm_token'], _token);
  });

  test('another installation, account or platform is left alone', () async {
    final others = [
      _row('other-install', 'iPhone · 5E6F7A8B'),
      _row('other-account', _oldName, user: 'someone-else'),
      _row('other-platform', _oldName, type: 'android'),
      _row('generic', 'iPhone'),
    ];
    final expected = others.map(Map<String, Object?>.of).toList();
    rows.addAll(others);
    expect(await devices.registerCurrentDevice(), isTrue);
    expect(rows, hasLength(5));
    expect(rows, containsAll(expected));
    expect(devices.getCurrentDeviceId(), 'original');
  });

  test(
    'an already-created new row is kept and stale duplicates removed',
    () async {
      rows.add(_row('current', _currentName));
      expect(await devices.registerCurrentDevice(), isTrue);
      expect(rows, hasLength(1));
      expect(devices.getCurrentDeviceId(), 'current');
      expect(rows.single['device_name'], _currentName);
      expect(rows.single['fcm_token'], _token);
    },
  );

  test('failed lookup does not create a duplicate and can retry', () async {
    failLookup = true;
    expect(await devices.registerCurrentDevice(), isFalse);
    expect(rows, hasLength(1));
    expect(rows.single['device_name'], _oldName);
    failLookup = false;
    expect(await devices.registerCurrentDevice(), isTrue);
    expect(rows, hasLength(1));
  });

  test('failed rename does not create a duplicate and can retry', () async {
    failRename = true;
    expect(await devices.registerCurrentDevice(), isFalse);
    expect(rows, hasLength(1));
    expect(rows.single['device_name'], _oldName);
    failRename = false;
    expect(await devices.registerCurrentDevice(), isTrue);
    expect(rows, hasLength(1));
  });

  test('duplicates are retained if the new registration fails', () async {
    rows.add(_row('current', _currentName));
    failUpsert = true;
    expect(await devices.registerCurrentDevice(), isFalse);
    expect(rows, hasLength(2));
  });

  test('names without a stable iOS suffix do not migrate', () async {
    deviceName = 'iPhone';
    expect(await devices.registerCurrentDevice(), isTrue);
    expect(rows, hasLength(2));
    expect(requests.where((r) => r.method == 'GET'), isEmpty);
  });

  test('other platforms keep their existing registration flow', () async {
    deviceType = 'android';
    expect(await devices.registerCurrentDevice(), isTrue);
    expect(requests.where((r) => r.method == 'GET'), isEmpty);
    expect(rows.first['device_name'], _oldName);
  });
}
