import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/reinstall_keychain_reset.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_keychain.dart';

void main() {
  const legacy = KeychainAccessibility.unlocked;
  const current = KeychainAccessibility.first_unlock;

  late FakeKeychain keychain;
  late Directory container;
  late int googleSignOuts;
  late bool failGoogleSignOut;

  setUp(() {
    keychain = FakeKeychain();
    container = Directory.systemTemp.createTempSync('container');
    addTearDown(() => container.deleteSync(recursive: true));
    googleSignOuts = 0;
    failGoogleSignOut = false;
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> launch() => clearKeychainLeftByEarlierInstall(
    storage: keychain,
    supportDirectory: () async => container,
    signOutGoogle: () async {
      if (failGoogleSignOut) throw Exception('network');
      googleSignOuts++;
    },
  );

  /// Deleting the app: the container and preferences go, the Keychain stays.
  void deleteApp() {
    container.listSync().forEach((e) => e.deleteSync(recursive: true));
    SharedPreferences.setMockInitialValues({});
  }

  String? keychainId() => keychain.items['ghostcopy_install_id']?.$1;
  String fileId() =>
      File(p.join(container.path, 'install_id')).readAsStringSync();

  group('a reinstall', () {
    setUp(() async {
      await launch(); // the earlier install records itself
      keychain.items
        ..['encryption_passphrase_u1'] = ('old passphrase', current)
        ..['encryption_passphrase_u2'] = ('older passphrase', legacy);
      deleteApp();
    });

    // One deleteAll, which the plugin runs with no accessibility constraint.
    test('clears what the earlier install left, and records itself', () async {
      await launch();

      expect(keychain.items.keys, ['ghostcopy_install_id']);
      expect(keychainId(), fileId());
    });

    // Google Sign-In keeps its account in the Keychain too, and would sign
    // the next person in as the last one.
    test('signs out the Google account it left', () async {
      await launch();

      expect(googleSignOuts, 1);
    });

    // Signing out deletes nothing of the new install's, so it is retried.
    test('retries a Google sign-out that failed, until it succeeds', () async {
      failGoogleSignOut = true;
      await launch();
      expect(googleSignOuts, 0);

      failGoogleSignOut = false;
      await launch();
      await launch();

      expect(googleSignOuts, 1);
    });

    test('pending Google cleanup survives losing preferences', () async {
      failGoogleSignOut = true;
      await launch();
      expect(keychainId(), fileId());

      // Simulate termination before UserDefaults flushed its pending flag.
      SharedPreferences.setMockInitialValues({});
      keychain.items['encryption_passphrase_new'] = ('new secret', current);
      failGoogleSignOut = false;
      await launch();
      await launch();

      expect(googleSignOuts, 1);
      expect(keychain.items['encryption_passphrase_new']!.$1, 'new secret');
    });

    test('Google cleanup is durably pending before sign-out runs', () async {
      var checked = false;
      await clearKeychainLeftByEarlierInstall(
        storage: keychain,
        supportDirectory: () async => container,
        signOutGoogle: () async {
          expect(
            File(p.join(container.path, 'google_sign_out_owed')).existsSync(),
            isTrue,
          );
          checked = true;
        },
      );
      expect(checked, isTrue);
      expect(
        File(p.join(container.path, 'google_sign_out_owed')).readAsStringSync(),
        'done',
      );
    });

    test(
      'failed pending cleanup write leaves the reinstall uncommitted',
      () async {
        final blocker = Directory(
          p.join(container.path, 'google_sign_out_owed.partial'),
        )..createSync();

        await launch();

        expect(googleSignOuts, 0);
        expect(
          File(p.join(container.path, 'install_id')).existsSync(),
          isFalse,
        );
        expect(
          keychain.items['encryption_passphrase_u1']!.$1,
          'old passphrase',
        );

        blocker.deleteSync();
        await launch();

        expect(googleSignOuts, 1);
        expect(keychain.items.keys, ['ghostcopy_install_id']);
        expect(keychainId(), fileId());
      },
    );

    // Recorded anyway, the fast path would skip the clear for good and leave
    // the earlier install's secrets behind.
    test('a clear that failed is not recorded, and is tried again', () async {
      keychain.failDeleteAll = true;
      await launch();

      expect(File(p.join(container.path, 'install_id')).existsSync(), isFalse);
      expect(keychain.items, contains('encryption_passphrase_u1'));

      keychain.failDeleteAll = false;
      await launch();

      expect(keychain.items.keys, ['ghostcopy_install_id']);
      expect(keychainId(), fileId());
    });
  });

  test('legacy pending preferences migrate to durable retry state', () async {
    await launch();
    SharedPreferences.setMockInitialValues({
      'ghostcopy_google_sign_out_owed': true,
    });
    failGoogleSignOut = true;
    await launch();

    SharedPreferences.setMockInitialValues({});
    failGoogleSignOut = false;
    await launch();
    await launch();

    expect(googleSignOuts, 1);
    expect(keychainId(), fileId());
  });

  test('a lost legacy flag removal cannot sign out a new account', () async {
    await launch();
    SharedPreferences.setMockInitialValues({
      'ghostcopy_google_sign_out_owed': true,
    });
    await launch();
    expect(googleSignOuts, 1);

    // Simulate UserDefaults restoring the old flag after successful cleanup.
    SharedPreferences.setMockInitialValues({
      'ghostcopy_google_sign_out_owed': true,
    });
    await launch();

    expect(googleSignOuts, 1);
  });

  // Empty preferences are not a reinstall: signed out, with every setting at
  // its default, an install has nothing else stored - and its passphrase is
  // its own.
  test('a normal launch preserves secrets and checks the install id', () async {
    await launch();
    keychain.items['encryption_passphrase_u1'] = ('mine', current);
    SharedPreferences.setMockInitialValues({
      'ghostcopy_install_id_in_keychain': true,
    });
    final reads = keychain.reads;

    await launch();

    expect(keychain.items, contains('encryption_passphrase_u1'));
    expect(keychain.reads, reads + 1);
  });

  // Unencrypted device backups restore the container and preferences, but
  // not a usable Keychain id on another phone. The old preferences flag is
  // therefore not evidence that the Keychain copy still exists.
  for (final restoredId in [null, 'another-device-id']) {
    test('a restored container repairs Keychain id $restoredId', () async {
      await launch();
      final restoredFileId = fileId();
      keychain.items.clear();
      if (restoredId != null) {
        keychain.items['ghostcopy_install_id'] = (restoredId, current);
      }
      keychain.items['encryption_passphrase_u1'] = ('mine', current);
      SharedPreferences.setMockInitialValues({
        'ghostcopy_install_id_in_keychain': true,
      });

      await launch();

      expect(fileId(), restoredFileId);
      expect(keychainId(), restoredFileId);
      expect(keychain.items['encryption_passphrase_u1']!.$1, 'mine');
      expect(googleSignOuts, 0);

      deleteApp();
      await launch();

      expect(keychain.items.keys, ['ghostcopy_install_id']);
      expect(keychainId(), fileId());
      expect(googleSignOuts, 1);
    });
  }

  for (final dropsWrite in [false, true]) {
    test(
      'a restored id repair retries an unsuccessful write ($dropsWrite)',
      () async {
        await launch();
        keychain.items.clear();
        keychain.items['encryption_passphrase_u1'] = ('mine', current);
        SharedPreferences.setMockInitialValues({
          'ghostcopy_install_id_in_keychain': true,
        });
        (dropsWrite ? keychain.dropWritesFor : keychain.failWritesFor).add(
          'ghostcopy_install_id',
        );

        await launch();
        expect(keychainId(), isNull);

        await launch();
        expect(keychainId(), fileId());
        expect(keychain.items['encryption_passphrase_u1']!.$1, 'mine');
        expect(googleSignOuts, 0);
      },
    );
  }

  // Preferences can lose a write the app was told had finished, if iOS ends
  // the app first. The id lives in a flushed file, so losing preferences is
  // not mistaken for a reinstall.
  test('lost preferences are not a reinstall', () async {
    await launch();
    keychain.items['encryption_passphrase_u1'] = ('mine', current);
    SharedPreferences.setMockInitialValues({});

    await launch();

    expect(keychain.items, contains('encryption_passphrase_u1'));
  });

  // The first launch of this version on an existing install: no id in the
  // Keychain yet, so nothing can be told apart, and nothing is deleted.
  test('an install from before the id existed keeps its passphrase', () async {
    keychain.items['encryption_passphrase_u1'] = ('mine', current);

    await launch();

    expect(keychain.items['encryption_passphrase_u1']!.$1, 'mine');
    expect(keychainId(), fileId());
  });

  // The file is written first, so a failed Keychain write leaves the id on
  // disk only - "not recorded yet", tried again - never in the Keychain only.
  test(
    'a failed Keychain write is retried, not taken for a reinstall',
    () async {
      keychain.failWritesFor.add('ghostcopy_install_id');
      await launch();
      keychain.items['encryption_passphrase_u1'] = ('mine', current);

      await launch();

      expect(keychain.items, contains('encryption_passphrase_u1'));
      expect(keychainId(), fileId());
    },
  );

  // A write can return and not persist. Rechecking the Keychain on the next
  // launch repairs the id so a subsequent reinstall can find it.
  test('a Keychain write that did not stick is retried', () async {
    keychain.dropWritesFor.add('ghostcopy_install_id');
    await launch();
    expect(keychainId(), isNull);

    await launch();

    expect(keychainId(), fileId());
  });
}
