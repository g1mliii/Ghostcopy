import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _GoogleSignIn extends Mock implements GoogleSignIn {}

// The plugin creates accounts internally; mock its authentication boundary.
// ignore: avoid_implementing_value_types
class _GoogleAccount extends Mock implements GoogleSignInAccount {}

class _GoogleAuthentication extends Mock
    implements GoogleSignInAuthentication {}

class _MemoryStorage extends GotrueAsyncStorage {
  final items = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => items[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      items[key] = value;

  @override
  Future<void> removeItem({required String key}) async => items.remove(key);
}

Map<String, Object?> _user(String id) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': '$id@example.com',
  'created_at': '2026-01-01T00:00:00Z',
  'is_anonymous': false,
  'app_metadata': <String, Object?>{},
  'user_metadata': <String, Object?>{},
};

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
    'user': _user(id),
  };
}

/// A phone never makes a guest at launch, and a desktop whose guest sign-in
/// failed has none until recovery retries. Creating an account then has no
/// guest to upgrade or link to, and both of those need a session - so every
/// Create Account on a fresh phone failed with AuthSessionMissingException.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late List<http.Request> requests;
  late _MemoryStorage confirmations;

  setUp(() {
    requests = [];
    confirmations = _MemoryStorage();
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        pkceAsyncStorage: _MemoryStorage(),
      ),
      httpClient: MockClient((request) async {
        requests.add(request);
        return switch (request.url.path) {
          // Confirmation required: a user, and no session.
          '/auth/v1/signup' => http.Response(jsonEncode(_user('new')), 200),
          '/auth/v1/token' => http.Response(
            jsonEncode(_session('google')),
            200,
          ),
          _ => http.Response('', 204, request: request),
        };
      }),
    );
  });

  tearDown(() => client.dispose());

  test('an email account is signed up when there is no guest', () async {
    final service = AuthService(
      client: client,
      confirmationStore: confirmations,
    );

    final response = await service.upgradeWithEmail(
      'new@example.com',
      'password1',
    );

    expect(response.user?.id, 'new');
    expect(requests.map((r) => r.url.path), ['/auth/v1/signup']);
    expect(client.auth.currentSession, isNull);
    expect(
      confirmations.items,
      isNotEmpty,
      reason: 'the emailed link has to be redeemable on this device',
    );
  });

  test('Google signs in when there is no guest to link', () async {
    final google = _GoogleSignIn();
    final account = _GoogleAccount();
    final credentials = _GoogleAuthentication();
    when(google.signInSilently).thenAnswer((_) async => null);
    when(google.signIn).thenAnswer((_) async => account);
    when(google.disconnect).thenAnswer((_) async => null);
    when(() => account.authentication).thenAnswer((_) async => credentials);
    when(() => credentials.idToken).thenReturn('google-id');
    when(() => credentials.accessToken).thenReturn('google-access');
    final service = AuthService(client: client, googleSignIn: google);

    expect(await service.linkGoogleIdentity(), isTrue);

    final body = jsonDecode(requests.last.body) as Map<String, Object?>;
    expect(body['link_identity'], isNot(isTrue));
    expect(client.auth.currentUser?.id, 'google');
  });
}
