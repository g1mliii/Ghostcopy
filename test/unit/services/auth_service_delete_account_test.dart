import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/repositories/clipboard_repository.dart';
import 'package:ghostcopy/services/auth_service.dart';
import 'package:ghostcopy/services/encryption_service.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Encryption extends Mock implements IEncryptionService {}

class _Repository extends Mock implements IClipboardRepository {}

/// gotrue's PKCE verifier slot, in memory.
class _PkceStorage extends GotrueAsyncStorage {
  final items = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => items[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      items[key] = value;

  @override
  Future<void> removeItem({required String key}) async => items.remove(key);
}

const _verifierKey = 'supabase.auth.token-code-verifier';

Map<String, Object?> _session(
  String id, {
  bool anonymous = false,
  String? provider,
}) {
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
      'identities': [
        if (provider != null)
          {
            'id': '$id-$provider',
            'user_id': id,
            'identity_data': <String, Object?>{},
            'provider': provider,
          },
      ],
    },
  };
}

/// Whether this host has the native Apple sheet, which decides whether an
/// Apple account is asked to confirm before deletion.
final _nativeApple = Platform.isIOS || Platform.isMacOS;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SupabaseClient client;
  late List<http.Request> requests;
  late int deleteStatus;
  late int reauthorizations;
  late String? appleCode;
  late _Encryption encryption;
  late bool signupFails;
  late _PkceStorage pkce;
  late Exception? reauthorizeError;

  Future<AuthService> signedInAs(Map<String, Object?> session) async {
    client = SupabaseClient(
      'https://example.com',
      'anon-key',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/functions/v1/delete-account') {
          return http.Response(
            deleteStatus == 200
                ? '{"deleted":true,"apple_revoked":null}'
                : '{"error":"delete_failed"}',
            deleteStatus,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (request.url.path == '/auth/v1/token') {
          // The browser callback's code exchange emits signedIn with the new
          // session; a password sign-in answered here emits the same event.
          return http.Response(jsonEncode(_session('apple-user')), 200);
        }
        if (request.url.path == '/auth/v1/signup') {
          if (signupFails) {
            return http.Response(
              '{"msg":"rate limited","code":429}',
              429,
              request: request,
            );
          }
          return http.Response(
            jsonEncode(_session('guest', anonymous: true)),
            200,
          );
        }
        return http.Response('', 204, request: request);
      }),
    );
    await client.auth.recoverSession(jsonEncode(session));
    requests.clear();
    return AuthService(
      client: client,
      encryptionService: encryption,
      clipboardRepository: _Repository(),
      appleReauthorize: () async {
        reauthorizations++;
        final error = reauthorizeError;
        if (error != null) throw error;
        return appleCode;
      },
      pkceStorage: pkce,
    );
  }

  setUp(() {
    requests = [];
    deleteStatus = 200;
    reauthorizations = 0;
    appleCode = 'fresh-code';
    signupFails = false;
    pkce = _PkceStorage();
    reauthorizeError = null;
    encryption = _Encryption();
    when(
      () => encryption.forgetPassphraseLocally(any()),
    ).thenAnswer((_) async {});
  });

  tearDown(() => client.dispose());

  Map<String, Object?> deleteBody() =>
      jsonDecode(
            requests
                .singleWhere((r) => r.url.path.endsWith('/delete-account'))
                .body,
          )
          as Map<String, Object?>;

  test('an email account is deleted and the device moves to a guest', () async {
    final service = await signedInAs(_session('user', provider: 'email'));

    expect(await service.deleteAccount(), AccountDeletionOutcome.deleted);

    expect(reauthorizations, 0);
    expect(deleteBody(), isEmpty);
    expect(client.auth.currentUser?.id, 'guest');
    expect(client.auth.currentUser?.isAnonymous, isTrue);
    // The passphrase for an account that no longer exists must not stay
    // in this device's Keychain.
    verify(() => encryption.forgetPassphraseLocally('user')).called(1);
  });

  test(
    'an Apple account confirms with Apple and sends the fresh code',
    () async {
      final service = await signedInAs(_session('user', provider: 'apple'));

      expect(await service.deleteAccount(), AccountDeletionOutcome.deleted);

      expect(reauthorizations, 1);
      expect(deleteBody(), {'apple_authorization_code': 'fresh-code'});
      expect(client.auth.currentUser?.id, 'guest');
    },
    skip: !_nativeApple,
  );

  test('backing out of the Apple sheet deletes nothing', () async {
    appleCode = null;
    final service = await signedInAs(_session('user', provider: 'apple'));

    expect(await service.deleteAccount(), AccountDeletionOutcome.cancelled);

    expect(requests, isEmpty);
    expect(client.auth.currentUser?.id, 'user');
  }, skip: !_nativeApple);

  test(
    'without the native sheet an Apple account is deleted without a code',
    () async {
      final service = await signedInAs(_session('user', provider: 'apple'));

      expect(await service.deleteAccount(), AccountDeletionOutcome.deleted);

      expect(reauthorizations, 0);
      expect(deleteBody(), isEmpty);
    },
    skip: _nativeApple,
  );

  test(
    'an Apple account is still deleted when Apple cannot give a code',
    () async {
      // No Apple ID signed in on this device, or Apple failing: only an
      // explicit cancel may stop the deletion (App Review 5.1.1(v)).
      reauthorizeError = Exception('AuthorizationErrorCode.unknown');
      final service = await signedInAs(_session('user', provider: 'apple'));

      expect(await service.deleteAccount(), AccountDeletionOutcome.deleted);

      expect(reauthorizations, 1);
      expect(deleteBody(), isEmpty);
      expect(client.auth.currentUser?.id, 'guest');
    },
    skip: !_nativeApple,
  );

  test('a failed deletion keeps the account signed in', () async {
    deleteStatus = 500;
    final service = await signedInAs(_session('user', provider: 'email'));

    await expectLater(service.deleteAccount(), throwsA(isA<Exception>()));

    expect(client.auth.currentUser?.id, 'user');
    expect(requests.map((r) => r.url.path), isNot(contains('/auth/v1/signup')));
    verifyNever(() => encryption.forgetPassphraseLocally(any()));
  });

  test(
    'a failed guest sign-in afterwards still reports the deletion',
    () async {
      // The account is already gone by then; saying "nothing was deleted"
      // would be false.
      signupFails = true;
      final service = await signedInAs(_session('user', provider: 'email'));

      expect(await service.deleteAccount(), AccountDeletionOutcome.deleted);
      verify(() => encryption.forgetPassphraseLocally('user')).called(1);
    },
  );

  group('browser sign-in waits for the callback', () {
    test('resolves once the new session arrives', () async {
      final service = await signedInAs(_session('guest', anonymous: true));
      final done = service.awaitBrowserSession(
        (session) => session.user.id != 'guest',
      );

      await client.auth.signInWithPassword(email: 'a@b.c', password: 'x');

      expect(await done, isTrue);
    });

    test('reports failure when the browser never comes back', () async {
      final service = await signedInAs(_session('guest', anonymous: true));

      expect(
        await service.awaitBrowserSession(
          (session) => session.user.id != 'guest',
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
    });

    test('an abandoned wait forgets the PKCE verifier', () async {
      // So a callback that arrives after the panel reported failure cannot
      // still switch accounts behind it.
      final service = await signedInAs(_session('guest', anonymous: true));
      pkce.items[_verifierKey] = 'verifier';

      await service.awaitBrowserSession(
        (session) => session.user.id != 'guest',
        timeout: const Duration(milliseconds: 50),
      );

      expect(pkce.items, isNot(contains(_verifierKey)));
      expect(service.isAwaitingBrowserSignIn, isFalse);
    });

    test('a completed sign-in leaves the verifier to gotrue', () async {
      final service = await signedInAs(_session('guest', anonymous: true));
      final done = service.awaitBrowserSession(
        (session) => session.user.id != 'guest',
      );
      pkce.items[_verifierKey] = 'verifier';

      await client.auth.signInWithPassword(email: 'a@b.c', password: 'x');

      expect(await done, isTrue);
      expect(pkce.items, contains(_verifierKey));
    });

    test('cancelling ends the wait at once', () async {
      final service = await signedInAs(_session('guest', anonymous: true));
      final done = service.awaitBrowserSession(
        (session) => session.user.id != 'guest',
      );
      expect(service.isAwaitingBrowserSignIn, isTrue);

      service.cancelBrowserSignIn();

      expect(await done, isFalse);
      expect(service.isAwaitingBrowserSignIn, isFalse);
    });

    test('a provider error ends the wait with that error', () async {
      final service = await signedInAs(_session('guest', anonymous: true));
      final done = service.awaitBrowserSession(
        (session) => session.user.id != 'guest',
      );

      service.failBrowserSignIn('That account is already linked');

      await expectLater(
        done,
        throwsA(
          isA<BrowserSignInException>().having(
            (e) => e.message,
            'message',
            'That account is already linked',
          ),
        ),
      );
    });

    test(
      'an earlier sign-in replayed by the auth stream does not count',
      () async {
        // onAuthStateChange replays every event this process has seen. A
        // sign-in to another account earlier in the session must not read as
        // this browser flow finishing.
        final service = await signedInAs(_session('guest', anonymous: true));
        await client.auth.signInWithPassword(email: 'a@b.c', password: 'x');
        await client.auth.recoverSession(
          jsonEncode(_session('guest', anonymous: true)),
        );

        expect(
          await service.awaitBrowserSession(
            (session) => session.user.id != 'guest',
            timeout: const Duration(milliseconds: 50),
          ),
          isFalse,
        );
      },
    );
  });
}
