import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/encryption_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// Regression tests for a silent user-switch bug.
///
/// `initialize()` used to be guarded by a bare `if (_initialized) return;`, with
/// no check on WHICH user it had been initialised for. Signing out signs the app
/// straight back in anonymously, so that keyless anonymous id became the loaded
/// state; signing back in then returned early and kept it. The visible symptom
/// was every clip showing as encrypted after signing back in without restarting
/// - and entering the right passphrase afterwards did not help, because
/// `_deriveKey` salts with the stale `_userId`.
void main() {
  const userA = 'aaaaaaaa-0000-0000-0000-000000000001';
  const userB = 'bbbbbbbb-0000-0000-0000-000000000002';

  late _MockSecureStorage storage;

  setUp(() {
    storage = _MockSecureStorage();
    // Only user A has a passphrase stored. Deriving a key is the observable
    // signal that initialize() actually ran for a given user.
    when(
      () => storage.read(key: 'encryption_passphrase_$userA'),
    ).thenAnswer((_) async => 'correct horse battery staple');
    when(
      () => storage.read(key: 'encryption_passphrase_$userB'),
    ).thenAnswer((_) async => null);
  });

  test('loads the key for the user it is initialised with', () async {
    final service = EncryptionService(secureStorage: storage);

    await service.initialize(userA);

    expect(
      await service.isEnabled(),
      isTrue,
      reason: 'user A has a passphrase, so a key should be derived',
    );
  });

  test('re-keys when a different user signs in', () async {
    final service = EncryptionService(secureStorage: storage);

    await service.initialize(userA);
    expect(await service.isEnabled(), isTrue);

    // The bug: this returned early and left user A's key loaded for user B.
    await service.initialize(userB);

    expect(
      await service.isEnabled(),
      isFalse,
      reason:
          'user B has no passphrase, so no key should be loaded - holding on '
          'to user A key here is what made every clip read as undecryptable, '
          'and left one account key material belonging to another',
    );
    verify(() => storage.read(key: 'encryption_passphrase_$userB')).called(1);
  });

  test('re-initialising for the same user does not re-derive', () async {
    final service = EncryptionService(secureStorage: storage);

    await service.initialize(userA);
    await service.initialize(userA);

    // The early return is still wanted for the common case: PBKDF2 at 100k
    // iterations costs ~600ms, and repeating it on every call would put that
    // back on the critical path.
    verify(() => storage.read(key: 'encryption_passphrase_$userA')).called(1);
    expect(await service.isEnabled(), isTrue);
  });
}
