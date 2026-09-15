import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _DeviceService extends Mock implements IDeviceService {}

class _GoogleSignIn extends Mock implements GoogleSignIn {}

// The plugin creates accounts internally; mock its authentication boundary.
// ignore: avoid_implementing_value_types
class _GoogleAccount extends Mock implements GoogleSignInAccount {}

class _GoogleAuthentication extends Mock
    implements GoogleSignInAuthentication {}

Map<String, Object?> _session(String id, {bool anonymous = false}) {
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
      'email': anonymous ? '' : '$id@example.com',
      'created_at': '2026-01-01T00:00:00Z',
      'is_anonymous': anonymous,
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late AuthService service;
  late _DeviceService devices;
  late List<http.Request> requests;
  late bool rejectLogin;
  late bool rejectDelete;
  late Map<String, Object?> oldSession;

  setUp(() async {
    requests = [];
    rejectLogin = false;
    rejectDelete = false;
    devices = _DeviceService();
    when(devices.getCurrentDeviceId).thenReturn('this-device');
    oldSession = _session('old-user', anonymous: true);
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/auth/v1/token') {
          if (rejectLogin) {
            return http.Response(
              '{"msg":"Invalid credentials"}',
              400,
              request: request,
            );
          }
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode(
              body['link_identity'] == true ? oldSession : _session('new-user'),
            ),
            200,
          );
        }
        if (request.method == 'DELETE' && rejectDelete) {
          return http.Response(
            '{"message":"offline","code":"503"}',
            503,
            request: request,
          );
        }
        return http.Response(
          request.method == 'GET' ? '[]' : '',
          request.method == 'GET' ? 200 : 204,
          request: request,
        );
      }),
    );
    await client.auth.recoverSession(jsonEncode(oldSession));
    service = AuthService(client: client, deviceService: devices);
    requests.clear();
  });

  tearDown(() async {
    service.dispose();
    await client.dispose();
  });

  test(
    'failed email login preserves the current account and makes no deletes',
    () async {
      rejectLogin = true;
      await expectLater(
        service.signInWithEmail('x@example.com', 'wrong'),
        throwsA(isA<AuthException>()),
      );
      expect(client.auth.currentUser?.id, 'old-user');
      expect(requests.map((r) => r.url.path), ['/auth/v1/token']);
    },
  );

  test(
    'successful login cleans anonymous data using only the old JWT',
    () async {
      await service.signInWithEmail('x@example.com', 'correct');
      expect(requests.map((r) => r.url.path), [
        '/auth/v1/token',
        '/rest/v1/rpc/cleanup_user_data',
      ]);
      final cleanup = requests.last;
      expect(
        cleanup.headers['Authorization'],
        'Bearer ${oldSession['access_token']}',
      );
      expect(jsonDecode(cleanup.body), {'p_user_id': 'old-user'});
      expect(client.auth.currentUser?.id, 'new-user');
      await client.from('devices').select();
      expect(
        requests.last.headers['Authorization'],
        'Bearer ${client.auth.currentSession!.accessToken}',
      );
    },
  );

  test('invalid QR session does not clean up the previous account', () async {
    rejectLogin = true;
    await expectLater(
      service.signInWithRefreshToken('bad-token'),
      throwsA(isA<AuthException>()),
    );
    expect(requests.every((r) => r.url.path == '/auth/v1/token'), isTrue);
    expect(client.auth.currentUser?.id, 'old-user');
  });

  test(
    'switching a permanent account releases only this device after login',
    () async {
      oldSession = _session('old-user');
      await client.auth.recoverSession(jsonEncode(oldSession));
      await service.signInWithEmail('x@example.com', 'correct');
      expect(requests.last.method, 'DELETE');
      expect(requests.last.url.queryParameters['id'], 'eq.this-device');
      expect(requests.last.url.queryParameters['user_id'], 'eq.old-user');
      expect(
        requests.last.headers['Authorization'],
        'Bearer ${oldSession['access_token']}',
      );
      expect(
        requests.any((r) => r.url.path.contains('cleanup_user_data')),
        isFalse,
      );
    },
  );

  test(
    'sign-out does not revoke the session if its device cannot be released',
    () async {
      rejectDelete = true;
      await expectLater(service.signOut(), throwsA(isA<PostgrestException>()));
      expect(client.auth.currentUser?.id, 'old-user');
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.queryParameters['id'], 'eq.this-device');
    },
  );

  test('cancelled native Google login makes no destructive requests', () async {
    final google = _GoogleSignIn();
    when(google.signInSilently).thenAnswer((_) async => null);
    when(google.signIn).thenAnswer((_) async => null);
    when(google.disconnect).thenAnswer((_) async => null);
    service = AuthService(
      client: client,
      deviceService: devices,
      googleSignIn: google,
    );
    expect(await service.signInWithGoogle(), isFalse);
    expect(requests, isEmpty);
  });

  test(
    'native Google upgrade requests identity linking with the existing session',
    () async {
      final google = _GoogleSignIn();
      final account = _GoogleAccount();
      when(google.signIn).thenAnswer((_) async => account);
      when(google.disconnect).thenAnswer((_) async => null);
      final credentials = _GoogleAuthentication();
      when(() => credentials.idToken).thenReturn('google-id');
      when(() => credentials.accessToken).thenReturn('google-access');
      when(() => account.authentication).thenAnswer((_) async => credentials);
      service = AuthService(
        client: client,
        deviceService: devices,
        googleSignIn: google,
      );
      expect(await service.linkGoogleIdentity(), isTrue);
      final body = jsonDecode(requests.single.body) as Map<String, Object?>;
      expect(body['link_identity'], isTrue);
      expect(
        requests.single.headers['Authorization'],
        'Bearer ${oldSession['access_token']}',
      );
      expect(client.auth.currentUser?.id, 'old-user');
    },
  );
}
