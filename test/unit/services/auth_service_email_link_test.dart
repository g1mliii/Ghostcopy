import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    'user': _user(id, anonymous: anonymous),
  };
}

Map<String, Object?> _user(String id, {bool anonymous = false}) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': anonymous ? '' : '$id@example.com',
  'created_at': '2026-01-01T00:00:00Z',
  'is_anonymous': anonymous,
  'app_metadata': <String, Object?>{},
  'user_metadata': <String, Object?>{},
};

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

/// A ghostcopy:// link can be opened by any web page, so a confirmation token
/// is only redeemed when this app asked for one - otherwise a page could sign
/// the app into the sender's own new account and collect every clip after.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late AuthService service;
  late _MemoryStorage storage;
  late List<String> calls;
  late String verifiedAs;

  setUp(() async {
    calls = [];
    verifiedAs = 'me';
    storage = _MemoryStorage();
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        pkceAsyncStorage: _MemoryStorage(),
      ),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        calls.add(path);
        return switch (path) {
          '/auth/v1/signup' => http.Response(
            jsonEncode(_session('guest', anonymous: true)),
            200,
          ),
          '/auth/v1/user' => http.Response(
            jsonEncode(_user('guest', anonymous: true)),
            200,
          ),
          '/auth/v1/verify' => http.Response(
            jsonEncode(_session(verifiedAs)),
            200,
          ),
          '/auth/v1/token' => http.Response(jsonEncode(_session('other')), 200),
          _ => http.Response('', 204, request: request),
        };
      }),
    );
    service = AuthService(client: client, confirmationStore: storage);
    await client.auth.signInAnonymously();
  });

  tearDown(() => client.dispose());

  test('redeems the confirmation this app asked for', () async {
    await service.upgradeWithEmail('Me@Example.com', 'password1');

    expect(await service.redeemEmailLink('hash', OtpType.emailChange), isTrue);

    expect(client.auth.currentUser!.email, 'me@example.com');
    expect(storage.items, isEmpty, reason: 'one confirmation, one redemption');
  });

  test('refuses a link when no confirmation is pending', () async {
    expect(await service.redeemEmailLink('hash', OtpType.signup), isFalse);

    expect(calls, isNot(contains('/auth/v1/verify')));
    expect(client.auth.currentUser!.isAnonymous, isTrue);
  });

  test('refuses a link while signed in to a permanent account', () async {
    await service.upgradeWithEmail('me@example.com', 'password1');
    await client.auth.signInWithPassword(
      email: 'other@example.com',
      password: 'password1',
    );

    expect(await service.redeemEmailLink('hash', OtpType.signup), isFalse);

    expect(calls, isNot(contains('/auth/v1/verify')));
    expect(client.auth.currentUser!.id, 'other');
  });

  test('signs out of a token for another address', () async {
    await service.upgradeWithEmail('me@example.com', 'password1');
    verifiedAs = 'attacker';

    expect(await service.redeemEmailLink('hash', OtpType.signup), isFalse);

    expect(client.auth.currentSession, isNull);
  });

  test('forgets a confirmation older than a day', () async {
    storage.items['ghostcopy_pending_confirmation'] = jsonEncode({
      'email': 'me@example.com',
      'at': DateTime.now()
          .subtract(const Duration(days: 2))
          .millisecondsSinceEpoch,
    });

    expect(await service.redeemEmailLink('hash', OtpType.signup), isFalse);

    expect(calls, isNot(contains('/auth/v1/verify')));
    expect(storage.items, isEmpty);
  });
}
