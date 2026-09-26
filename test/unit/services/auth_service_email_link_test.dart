import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, Object?> _session(String id, {bool anonymous = false}) {
  final expires =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'sub': id, 'exp': expires})))
      .replaceAll('=', '');
  return {
    // A header setSession can decode: it checks the token before using it.
    'access_token': 'eyJhbGciOiJIUzI1NiJ9.$payload.c2ln',
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

/// The user id in a bearer token minted by [_session].
String _subject(String? authorization) {
  final payload = authorization!.split('.')[1];
  final json = utf8.decode(base64Url.decode(base64Url.normalize(payload)));
  return (jsonDecode(json) as Map<String, dynamic>)['sub'] as String;
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

class _Devices extends Mock implements IDeviceService {}

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
  late _Devices devices;
  Completer<void>? verifyGate;

  setUp(() async {
    calls = [];
    verifiedAs = 'me';
    verifyGate = null;
    storage = _MemoryStorage();
    devices = _Devices();
    when(devices.getCurrentDeviceId).thenReturn('this-pc');
    when(devices.registerCurrentDevice).thenAnswer((_) async => true);
    final mock = MockClient((request) async {
      final path = request.url.path;
      calls.add(path);
      if (path == '/auth/v1/verify') await verifyGate?.future;
      return switch (path) {
        // An email sign-up awaits confirmation, so it has no session yet.
        '/auth/v1/signup'
            when (jsonDecode(request.body) as Map)['email'] != null =>
          _json(_user('new')),
        '/auth/v1/signup' => _json(_session('guest', anonymous: true)),
        // Whoever the presented token belongs to, as the server answers.
        '/auth/v1/user' when request.method == 'GET' => _json(
          _user(
            _subject(request.headers['Authorization']),
            anonymous: _subject(request.headers['Authorization']) == 'guest',
          ),
        ),
        '/auth/v1/user' => _json(_user('guest', anonymous: true)),
        '/auth/v1/verify' => _json(_session(verifiedAs)),
        '/auth/v1/token' => _json(_session('other')),
        _ => http.Response('', 204, request: request),
      };
    });
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      authOptions: AuthClientOptions(
        autoRefreshToken: false,
        pkceAsyncStorage: _MemoryStorage(),
      ),
      httpClient: mock,
    );
    service = AuthService(
      client: client,
      deviceService: devices,
      confirmationStore: storage,
      detachedAuth: () => GoTrueClient(
        url: 'https://example.com/auth/v1',
        autoRefreshToken: false,
        httpClient: mock,
      ),
    );
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

  // It used to install the session first and sign out after: every listener
  // switched to the sender's account, and the app was left with no session
  // at all - not even the guest it started with.
  test('never installs a token for another address', () async {
    await service.upgradeWithEmail('me@example.com', 'password1');
    verifiedAs = 'attacker';
    final seen = <String?>[];
    final sub = client.auth.onAuthStateChange.listen(
      (s) => seen.add(s.session?.user.id),
    );

    expect(await service.redeemEmailLink('hash', OtpType.signup), isFalse);
    await pumpEventQueue();

    expect(calls, contains('/auth/v1/verify'));
    expect(client.auth.currentUser!.id, 'guest');
    expect(seen, isNot(contains('attacker')));
    await sub.cancel();
  });

  test('a sign-up with no session lands signed in and registered', () async {
    await client.auth.signOut();
    await service.signUpWithEmail('me@example.com', 'password1');
    expect(client.auth.currentSession, isNull);

    expect(await service.redeemEmailLink('hash', OtpType.signup), isTrue);

    expect(client.auth.currentUser!.id, 'me');
    verify(devices.registerCurrentDevice).called(1);
  });

  // The launch sign-in is retried in the background while the user signs up.
  // A guest landing after the confirmed account replaced it.
  test('a guest sign-in retried meanwhile waits for the link', () async {
    await client.auth.signOut();
    await service.signUpWithEmail('me@example.com', 'password1');
    verifyGate = Completer<void>();

    final redeeming = service.redeemEmailLink('hash', OtpType.signup);
    await pumpEventQueue();
    await service.initialize();
    expect(client.auth.currentSession, isNull, reason: 'no guest meanwhile');
    verifyGate!.complete();

    expect(await redeeming, isTrue);
    expect(client.auth.currentUser!.id, 'me');
  });

  group('refreshIfAwaitingConfirmation', () {
    test('refreshes the guest being upgraded, once per interval', () async {
      await service.upgradeWithEmail('me@example.com', 'password1');

      await service.refreshIfAwaitingConfirmation();
      await service.refreshIfAwaitingConfirmation();

      expect(calls.where((c) => c == '/auth/v1/token'), hasLength(1));
    });

    test('leaves a guest alone that is not the one upgraded', () async {
      storage.items['ghostcopy_pending_confirmation'] = jsonEncode({
        'email': 'me@example.com',
        'user': 'an-earlier-guest',
        'at': DateTime.now().millisecondsSinceEpoch,
      });

      await service.refreshIfAwaitingConfirmation();

      expect(calls, isNot(contains('/auth/v1/token')));
    });
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

  // Sentry, 1.0.0+11 on macOS: a ghostcopy://auth-callback?code= arriving with
  // no stored verifier. supabase_flutter pushes that failure into
  // onAuthStateChange as an error, and a listener without onError took the
  // app down.
  test('a failed deep-link exchange does not reach subscribers', () async {
    final events = <AuthChangeEvent>[];
    final sub = service.authStateChanges.listen((s) => events.add(s.event));

    try {
      await client.auth.getSessionFromUrl(
        Uri.parse('ghostcopy://auth-callback?code=stale'),
      );
      fail('there is no verifier, so the exchange must throw');
    } on AuthException catch (error, stackTrace) {
      // What supabase_flutter's _handleDeeplink does with it.
      // ignore: invalid_use_of_internal_member
      client.auth.notifyException(error, stackTrace);
    }
    await client.auth.signOut();
    await pumpEventQueue();

    // A new subscriber is replayed the error as well.
    final late = <AuthChangeEvent>[];
    final lateSub = service.authStateChanges.listen((s) => late.add(s.event));
    await pumpEventQueue();

    expect(events, contains(AuthChangeEvent.signedOut));
    expect(late, contains(AuthChangeEvent.signedOut));
    await sub.cancel();
    await lateSub.cancel();
  });
}
