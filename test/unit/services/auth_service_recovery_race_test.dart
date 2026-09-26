import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _DeviceService extends Mock implements IDeviceService {}

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

/// The background retry of a failed launch sign-in (recoverSession) and the
/// auth panel share one Supabase client, and both install the session they
/// get back. A guest response landing after an email sign-in replaced the
/// account the user had just signed into.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late AuthService service;
  late List<String> calls;
  late Completer<void> guestReply;
  late Completer<void> emailReply;

  setUp(() {
    calls = [];
    guestReply = Completer<void>();
    emailReply = Completer<void>();
    final devices = _DeviceService();
    when(devices.getCurrentDeviceId).thenReturn(null);
    when(devices.registerCurrentDevice).thenAnswer((_) async => true);
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        calls.add(path);
        if (path == '/auth/v1/signup') {
          await guestReply.future;
          return http.Response(
            jsonEncode(_session('guest', anonymous: true)),
            200,
          );
        }
        if (path == '/auth/v1/token') {
          await emailReply.future;
          return http.Response(jsonEncode(_session('email-user')), 200);
        }
        return http.Response(
          request.method == 'GET' ? '[]' : '',
          request.method == 'GET' ? 200 : 204,
          request: request,
        );
      }),
    );
    service = AuthService(client: client, deviceService: devices);
  });

  tearDown(() async {
    service.dispose();
    await client.dispose();
  });

  test('a sign-in waits out a guest sign-in already in flight', () async {
    // The retry is mid-request...
    final retry = service.initialize().catchError((Object _) {});
    await pumpEventQueue();
    // ...when the user signs in with email.
    final signIn = service.signInWithEmail('a@example.com', 'secret');
    emailReply.complete();
    await pumpEventQueue();
    expect(
      calls,
      isNot(contains('/auth/v1/token')),
      reason: 'the email sign-in must not start until the guest one is done',
    );

    guestReply.complete();
    await retry;
    await signIn;

    expect(client.auth.currentUser?.id, 'email-user');
  });

  test('no guest sign-in starts while a sign-in is in progress', () async {
    final signIn = service.signInWithEmail('a@example.com', 'secret');
    await pumpEventQueue();

    await service.initialize();
    expect(calls, isNot(contains('/auth/v1/signup')));

    emailReply.complete();
    guestReply.complete();
    await signIn;
    expect(client.auth.currentUser?.id, 'email-user');
  });
}
