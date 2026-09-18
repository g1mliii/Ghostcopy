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

  Future<void> migrate() => migrateKeychainAccessibility(
    storage: keychain,
    keys: const [passphraseKey, hashKey],
  );

  test('moves an existing passphrase to first_unlock', () async {
    keychain.items[passphraseKey] = ('correct horse battery staple', legacy);

    await migrate();

    expect(keychain.items[passphraseKey], ('correct horse battery staple', migrated));
    expect(
      await keychain.read(key: passphraseKey, iOptions: passphraseIosOptions),
      'correct horse battery staple',
      reason: 'the whole point is that it is now readable under the new options',
    );
  });

  test('a fresh install writes nothing', () async {
    await migrate();

    expect(keychain.items, isEmpty);
  });

  test('is a no-op once already migrated', () async {
    keychain.items[passphraseKey] = ('secret', migrated);

    await migrate();
    await migrate();

    expect(keychain.items[passphraseKey], ('secret', migrated));
  });

  test('puts the passphrase back if the new write fails', () async {
    // The window the incident fell into: the old item is deleted before the new
    // one can be added, because the add would otherwise collide. If the write
    // fails there and nothing restores it, the user's clips are unreadable
    // forever - the failure has to leave things exactly as it found them.
    keychain.items[passphraseKey] = ('secret', legacy);
    keychain.failWritesFor.add(passphraseKey);

    await migrate();

    expect(
      keychain.items[passphraseKey],
      ('secret', legacy),
      reason: 'still readable under the old options, which is where it started',
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

  test('survives a read that throws, without deleting anything', () async {
    final throwing = _ThrowingKeychain()..items[passphraseKey] = ('secret', legacy);

    await migrateKeychainAccessibility(
      storage: throwing,
      keys: const [passphraseKey],
    );

    expect(throwing.items[passphraseKey], ('secret', legacy));
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
