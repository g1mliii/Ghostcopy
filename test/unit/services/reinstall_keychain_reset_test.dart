import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/keychain_accessibility.dart';
import 'package:ghostcopy/services/reinstall_keychain_reset.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Keychain as far as this cares: the install id, and what was cleared.
class _Keychain {
  String? id;
  final List<IOSOptions> cleared = [];
  bool failWrite = false;
  bool failDelete = false;

  Future<String?> read() async => id;

  Future<void> write(String value) async {
    if (failWrite) throw Exception('Keychain write failed');
    id = value;
  }

  Future<void> deleteAll(IOSOptions options) async {
    if (failDelete) throw Exception('Keychain locked');
    cleared.add(options);
    id = null; // the id lives in the same service
  }
}

void main() {
  late _Keychain keychain;

  setUp(() => keychain = _Keychain());

  Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Future<void> launch(SharedPreferences prefs) =>
      clearKeychainLeftByEarlierInstall(
        preferences: prefs,
        readKeychainId: keychain.read,
        writeKeychainId: keychain.write,
        deleteAll: keychain.deleteAll,
      );

  test('a reinstall clears both places the passphrase lived', () async {
    // The Keychain remembers an install whose preferences are gone.
    keychain.id = 'earlier-install';

    await launch(await prefsWith({}));

    expect(keychain.cleared, [
      passphraseIosOptions,
      legacyPassphraseIosOptions,
    ]);
  });

  // Empty preferences are not a reinstall: signed out, with every setting
  // at its default, an install has none - and its passphrase is its own.
  test(
    'an install with no preferences but its own id keeps its Keychain',
    () async {
      final prefs = await prefsWith({});
      await launch(prefs); // records the id; nothing else is stored

      await launch(prefs);

      expect(keychain.cleared, isEmpty);
    },
  );

  // The first launch of this version on an existing install: no id anywhere
  // yet, so nothing can be told apart, and nothing is deleted.
  test(
    'an install from before the id existed is left alone, then recorded',
    () async {
      final prefs = await prefsWith({});

      await launch(prefs);

      expect(keychain.cleared, isEmpty);
      expect(keychain.id, isNotNull);
      expect(prefs.getString('ghostcopy_install_id'), keychain.id);
    },
  );

  test('an ordinary launch does nothing', () async {
    final prefs = await prefsWith({});
    await launch(prefs);
    final id = keychain.id;

    await launch(prefs);

    expect(keychain.cleared, isEmpty);
    expect(keychain.id, id);
  });

  // Preferences are written first, so a failed Keychain write leaves the id
  // in preferences only - "not recorded yet" - never in the Keychain only,
  // which would read as a reinstall.
  test(
    'a failed Keychain write is retried, not taken for a reinstall',
    () async {
      final prefs = await prefsWith({});
      keychain.failWrite = true;
      await launch(prefs);
      expect(keychain.id, isNull);

      keychain.failWrite = false;
      await launch(prefs);

      expect(keychain.cleared, isEmpty);
      expect(keychain.id, prefs.getString('ghostcopy_install_id'));
    },
  );

  test('a clear that failed is tried again on the next launch', () async {
    keychain
      ..id = 'earlier-install'
      ..failDelete = true;
    final prefs = await prefsWith({});
    await launch(prefs);
    expect(prefs.getString('ghostcopy_install_id'), isNull);

    keychain.failDelete = false;
    await launch(prefs);

    expect(keychain.cleared, [
      passphraseIosOptions,
      legacyPassphraseIosOptions,
    ]);
  });
}
