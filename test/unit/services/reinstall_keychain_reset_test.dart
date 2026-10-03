import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/install_id.dart';
import 'package:ghostcopy/services/reinstall_keychain_reset.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_keychain.dart';

void main() {
  const legacy = KeychainAccessibility.unlocked;
  const current = KeychainAccessibility.first_unlock;

  late FakeKeychain keychain;
  late int googleSignOuts;

  setUp(() {
    keychain = FakeKeychain();
    googleSignOuts = 0;
  });

  Future<void> launch() => clearKeychainLeftByEarlierInstall(
    storage: keychain,
    signOutGoogle: () async => googleSignOuts++,
  );

  /// What a deleted install leaves: its id and passphrases, under both
  /// accessibility values the passphrase may have been written with.
  void leftByEarlierInstall() => keychain.items
    ..['ghostcopy_install_id'] = ('earlier-install', current)
    ..['encryption_passphrase_u1'] = ('old passphrase', current)
    ..['encryption_passphrase_u2'] = ('older passphrase', legacy);

  group('a reinstall', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      leftByEarlierInstall();
    });

    test('clears what the earlier install left, and records itself', () async {
      await launch();

      final prefs = await SharedPreferences.getInstance();
      expect(keychain.items.keys, ['ghostcopy_install_id']);
      expect(
        keychain.items['ghostcopy_install_id']!.$1,
        prefs.getString(installIdKey),
      );
    });

    // Google Sign-In keeps its account in the Keychain too, and would sign
    // the next person in as the last one.
    test('signs out the Google account it left', () async {
      await launch();

      expect(googleSignOuts, 1);
    });

    // Retrying could not tell the leftover from a passphrase the user set
    // after the failure, on this same launch.
    test('is recorded even when the clear fails, and not retried', () async {
      keychain.failDeleteAll = true;
      await launch();
      keychain.failDeleteAll = false;
      keychain.items['encryption_passphrase_u3'] = ('set since', current);

      await launch();

      expect(keychain.items, contains('encryption_passphrase_u3'));
    });
  });

  // Empty preferences are not a reinstall: signed out, with every setting at
  // its default, an install has nothing else stored - and its passphrase is
  // its own.
  test('a launch after the id is recorded leaves the Keychain alone', () async {
    SharedPreferences.setMockInitialValues({});
    await launch();
    keychain.items['encryption_passphrase_u1'] = ('mine', current);
    final reads = keychain.reads;

    await launch();

    expect(keychain.items, contains('encryption_passphrase_u1'));
    expect(keychain.reads, reads, reason: 'a normal launch reads nothing');
  });

  // The first launch of this version on an existing install: no id in the
  // Keychain yet, so nothing can be told apart, and nothing is deleted.
  test('an install from before the id existed keeps its passphrase', () async {
    SharedPreferences.setMockInitialValues({installIdKey: 'existing-device'});
    keychain.items['encryption_passphrase_u1'] = ('mine', current);

    await launch();

    expect(keychain.items['encryption_passphrase_u1']!.$1, 'mine');
    expect(keychain.items['ghostcopy_install_id']!.$1, 'existing-device');
  });

  // Preferences are written first, so a failed Keychain write leaves the id
  // in preferences only - "not recorded yet" - never in the Keychain only,
  // which would read as a reinstall.
  test(
    'a failed Keychain write is retried, not taken for a reinstall',
    () async {
      SharedPreferences.setMockInitialValues({});
      keychain.failWritesFor.add('ghostcopy_install_id');
      await launch();
      keychain.items['encryption_passphrase_u1'] = ('mine', current);

      await launch();

      final prefs = await SharedPreferences.getInstance();
      expect(keychain.items, contains('encryption_passphrase_u1'));
      expect(
        keychain.items['ghostcopy_install_id']!.$1,
        prefs.getString(installIdKey),
      );
    },
  );
}
