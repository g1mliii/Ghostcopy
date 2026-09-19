import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/keychain_accessibility.dart';
import 'package:mocktail/mocktail.dart';

/// A Keychain with the two behaviours that caused the original incident.
///
/// Stubbing call-by-call would let these tests pass against a migration that
/// only works because the stubs were written to match it. The rules modelled
/// here are the ones that actually bite:
///
///  1. An item is identified by key alone. Accessibility is an attribute, not
///     part of that identity, so the old and new items can never coexist - and
///     an add on top of an existing item fails, whatever its accessibility.
///     That is errSecDuplicateItem (-25299), the write half of the incident.
///  2. A read carries accessibility in its query, so an item written under one
///     value is invisible to a read under another. That is the read half: "No
///     existing passphrase found" about an item that is demonstrably there.
class _FakeKeychain extends Mock implements FlutterSecureStorage {
  final Map<String, (String value, KeychainAccessibility accessibility)> items =
      {};

  /// Keys whose next write throws, to exercise the window where the value
  /// exists only on the stack.
  final Set<String> failWritesFor = {};

  /// Every read, so the test below can hold the Keychain round trips down.
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    final item = items[key];
    if (item == null) return null;
    return item.$2 == iOptions?.accessibility ? item.$1 : null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWritesFor.remove(key)) {
      throw Exception('simulated secure-storage failure');
    }
    if (items.containsKey(key)) {
      throw Exception('-25299 duplicate item');
    }
    items[key] = (
      value!,
      iOptions?.accessibility ?? KeychainAccessibility.unlocked,
    );
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (items[key]?.$2 == iOptions?.accessibility) items.remove(key);
  }
}

void main() {
  const passphraseKey = 'encryption_passphrase_u1';
  const hashKey = 'encryption_verification_hash_u1';
  const legacy = KeychainAccessibility.unlocked;
  const migrated = KeychainAccessibility.first_unlock;

  late _FakeKeychain keychain;

  setUp(() => keychain = _FakeKeychain());

  Future<Map<String, String?>> migrate() => migrateKeychainAccessibility(
    storage: keychain,
    keys: const [passphraseKey, hashKey],
  );

  test('moves an existing passphrase to first_unlock', () async {
    keychain.items[passphraseKey] = ('correct horse battery staple', legacy);

    final current = await migrate();

    expect(keychain.items[passphraseKey], ('correct horse battery staple', migrated));
    expect(
      current[passphraseKey],
      'correct horse battery staple',
      reason: 'handed back so initialize() need not read the same key again',
    );
    expect(
      await keychain.read(key: passphraseKey, iOptions: passphraseIosOptions),
      'correct horse battery staple',
      reason: 'the whole point is that it is now readable under the new options',
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

    final current = await migrate();

    expect(
      keychain.items[passphraseKey],
      ('secret', legacy),
      reason: 'still readable under the old options, which is where it started',
    );
    expect(
      current[passphraseKey],
      isNull,
      reason:
          'the value is under the OLD options, so a read under the new ones - '
          'which is what this stands in for - would not find it either. '
          'Reporting it here would have initialize() derive a key from a '
          'passphrase that hasPassphrase() cannot see.',
    );
  });

  test('does not lose the other key when one fails', () async {
    keychain.items[passphraseKey] = ('secret', legacy);
    keychain.items[hashKey] = ('hash', legacy);
    keychain.failWritesFor.add(passphraseKey);

    await migrate();

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

  test('survives a read that throws, without deleting anything', () async {
    final throwing = _ThrowingKeychain()..items[passphraseKey] = ('secret', legacy);

    final current = await migrateKeychainAccessibility(
      storage: throwing,
      keys: const [passphraseKey],
    );

    expect(throwing.items[passphraseKey], ('secret', legacy));
    expect(current[passphraseKey], isNull);
  });
}

/// Reads always throw - a locked device, or the Keychain simply refusing.
class _ThrowingKeychain extends _FakeKeychain {
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
