import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/models/exceptions.dart';
import 'package:ghostcopy/services/impl/keychain_accessibility.dart';

import 'fake_keychain.dart';

void main() {
  const passphraseKey = 'encryption_passphrase_u1';
  const hashKey = 'encryption_verification_hash_u1';
  const legacy = KeychainAccessibility.unlocked;
  const migrated = KeychainAccessibility.first_unlock;

  late FakeKeychain keychain;

  setUp(() => keychain = FakeKeychain());

  Future<Map<String, String?>> migrate() => migrateKeychainAccessibility(
    storage: keychain,
    keys: const [passphraseKey, hashKey],
  );

  test('moves an existing passphrase to first_unlock', () async {
    keychain.items[passphraseKey] = ('correct horse battery staple', legacy);

    final current = await migrate();

    expect(keychain.items[passphraseKey], (
      'correct horse battery staple',
      migrated,
    ));
    expect(
      current[passphraseKey],
      'correct horse battery staple',
      reason: 'handed back so initialize() need not read the same key again',
    );
    expect(
      await keychain.read(key: passphraseKey, iOptions: passphraseIosOptions),
      'correct horse battery staple',
      reason:
          'the whole point is that it is now readable under the new options',
    );
  });

  test('a fresh install writes nothing', () async {
    final current = await migrate();

    expect(keychain.items, isEmpty);
    expect(current[passphraseKey], isNull);
  });

  test('is a no-op once already migrated', () async {
    keychain.items[passphraseKey] = ('secret', migrated);

    await migrate();
    final current = await migrate();

    expect(keychain.items[passphraseKey], ('secret', migrated));
    expect(
      current[passphraseKey],
      'secret',
      reason: 'the already-migrated read is the one initialize() consumes',
    );
  });

  test('puts the passphrase back if the new write fails', () async {
    // The window the incident fell into: the old item is deleted before the new
    // one can be added, because the add would otherwise collide. If the write
    // fails there and nothing restores it, the user's clips are unreadable
    // forever - the failure has to leave things exactly as it found them.
    keychain.items[passphraseKey] = ('secret', legacy);
    keychain.failWritesFor.add(passphraseKey);

    await expectLater(migrate(), throwsA(isA<SecurityException>()));

    expect(keychain.items[passphraseKey], ('secret', legacy));
    final retried = await migrate();
    expect(retried[passphraseKey], 'secret');
  });

  test('does not lose the other key when one fails', () async {
    keychain.items[passphraseKey] = ('secret', legacy);
    keychain.items[hashKey] = ('hash', legacy);
    keychain.failWritesFor.add(passphraseKey);

    await expectLater(migrate(), throwsA(isA<SecurityException>()));

    expect(keychain.items[passphraseKey], ('secret', legacy));
    expect(
      keychain.items[hashKey],
      ('hash', migrated),
      reason: 'a failure on the first key must not abandon the second',
    );
  });

  test('reads each key once when there is nothing left to migrate', () async {
    // The steady state, which is every launch after the first. The migration
    // has to read the passphrase anyway to know whether it has work to do, so
    // it hands that value back and initialize() consumes it instead of issuing
    // an identical read - this asserts the reads it does do stay at one per
    // key, which is what makes that worth doing.
    keychain.items[passphraseKey] = ('secret', migrated);
    keychain.items[hashKey] = ('hash', migrated);

    final current = await migrate();

    expect(keychain.reads, 2, reason: 'one per key, and no legacy probe');
    expect(current[passphraseKey], 'secret');
    expect(current[hashKey], 'hash');
  });

  test('a read failure is not reported as an absent passphrase', () async {
    final throwing = _ThrowingKeychain()
      ..items[passphraseKey] = ('secret', legacy);

    await expectLater(
      migrateKeychainAccessibility(
        storage: throwing,
        keys: const [passphraseKey],
      ),
      throwsA(isA<SecurityException>()),
    );

    expect(throwing.items[passphraseKey], ('secret', legacy));
  });

  test('an unverified migration restores the key and fails closed', () async {
    keychain.items[passphraseKey] = ('secret', legacy);
    keychain.dropWritesFor.add(passphraseKey);

    await expectLater(migrate(), throwsA(isA<SecurityException>()));

    expect(keychain.items[passphraseKey], ('secret', legacy));
  });
}

/// Reads always throw - a locked device, or the Keychain simply refusing.
class _ThrowingKeychain extends FakeKeychain {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('errSecInteractionNotAllowed');
}
