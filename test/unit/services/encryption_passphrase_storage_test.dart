import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/services/impl/encryption_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// What happens to the stored passphrase when secure storage misbehaves.
///
/// Both cases below share a shape: the passphrase is deleted before the new
/// value can be written, because a write is not an upsert - the Keychain
/// rejects an add whose item already exists. That delete is not optional, so
/// the only protection is what the failure path does afterwards.
void main() {
  const userId = 'aaaaaaaa-0000-0000-0000-000000000001';
  const passphraseKey = 'encryption_passphrase_$userId';
  const hashKey = 'encryption_verification_hash_$userId';

  late _MockSecureStorage storage;

  setUp(() {
    storage = _MockSecureStorage();
    when(() => storage.delete(key: any(named: 'key'))).thenAnswer((_) async {});
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenAnswer((_) async {});
  });

  test('a failed write puts the previous passphrase back', () async {
    // The replacement flows - QR import, or entering a different passphrase -
    // reach this with a value already stored. A transient failure here used to
    // leave nothing at all behind, so every clip encrypted under the old
    // passphrase became unreadable at the next launch, permanently.
    when(
      () => storage.read(key: passphraseKey),
    ).thenAnswer((_) async => 'the old passphrase');
    when(() => storage.read(key: hashKey)).thenAnswer((_) async => null);
    when(
      () => storage.write(key: passphraseKey, value: 'the new passphrase'),
    ).thenThrow(Exception('device refused to store it'));

    final service = EncryptionService(secureStorage: storage);
    await service.initialize(userId);

    await expectLater(
      service.setPassphrase('the new passphrase'),
      throwsA(isA<PassphraseStorageException>()),
    );

    verify(
      () => storage.write(key: passphraseKey, value: 'the old passphrase'),
    ).called(1);
  });

  test('a failure after the passphrase lands still restores it', () async {
    // The window the first rollback missed. The verification hash is written
    // after the passphrase has already been replaced, so a failure there left
    // the NEW passphrase on disk while setPassphrase reported failure and the
    // OLD key stayed in memory. Next launch loads the new one and every clip
    // encrypted under the old key is unreadable - the same loss the rollback
    // exists to prevent, one step later.
    when(
      () => storage.read(key: passphraseKey),
    ).thenAnswer((_) async => 'the old passphrase');
    when(
      () => storage.read(key: hashKey),
    ).thenAnswer((_) async => 'the old hash');
    when(
      () => storage.write(
        key: hashKey,
        value: any(named: 'value'),
      ),
    ).thenThrow(Exception('device refused the hash'));
    // The restore writes the old hash back, which must not throw.
    when(
      () => storage.write(key: hashKey, value: 'the old hash'),
    ).thenAnswer((_) async {});

    final service = EncryptionService(secureStorage: storage);
    await service.initialize(userId);

    await expectLater(
      service.setPassphrase('the new passphrase'),
      throwsA(isA<PassphraseStorageException>()),
    );

    verify(
      () => storage.write(key: passphraseKey, value: 'the old passphrase'),
    ).called(1);
    verify(() => storage.write(key: hashKey, value: 'the old hash')).called(1);
  });

  test('a failed delete is reported, not swallowed', () async {
    // Returning normally told the settings screen encryption was off while the
    // passphrase was still on disk - and initialize() reads it again on the
    // next launch, so it came back by itself with the user believing they had
    // turned it off.
    when(
      () => storage.read(key: passphraseKey),
    ).thenAnswer((_) async => 'a passphrase');
    when(() => storage.read(key: hashKey)).thenAnswer((_) async => null);
    when(
      () => storage.delete(key: passphraseKey),
    ).thenThrow(Exception('device refused to delete it'));

    final service = EncryptionService(secureStorage: storage);
    await service.initialize(userId);

    await expectLater(
      service.clearPassphrase(),
      throwsA(isA<PassphraseStorageException>()),
    );

    // Still attempted, and the in-memory key still dropped: failing to erase is
    // never a reason to abandon the rest of the teardown.
    verify(() => storage.delete(key: hashKey)).called(1);
    expect(await service.isEnabled(), isFalse);
  });
}
