import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'google_sign_in_config.dart';
import 'impl/keychain_accessibility.dart';

/// Clears what an earlier install of GhostCopy left in the iOS Keychain.
///
/// Deleting an iOS app deletes its container - files, preferences, caches -
/// but not its Keychain items, so the encryption passphrase outlived the app:
/// still on the phone after the user removed GhostCopy, and handed back to
/// whoever installed it next.
///
/// A reinstall is recognised by an install id kept in a file in the app's
/// container and copied into the Keychain. Found in the Keychain with no file
/// means the container was deleted while the Keychain was not, and only
/// deleting the app does that. The file is written, and flushed to disk,
/// before the Keychain copy: SharedPreferences promises no such thing, and an
/// id that reached the Keychain but not the disk would read as a reinstall
/// and cost an existing install its passphrase. Empty preferences are not
/// evidence either way - an install signed out with every setting at its
/// default has none.
///
/// An install from before this version has no id in the Keychain yet, so it
/// deletes nothing and is recorded; a passphrase left by one of those is not
/// recognised as left over, but every install from here on is.
///
/// A reinstall clears GhostCopy's Keychain items - one deleteAll, which the
/// plugin runs without an accessibility constraint, so the passphrase goes
/// whichever value it was written under - and signs out the Google account
/// Google Sign-In keeps there. The clear is never retried: the user may set
/// a passphrase this very launch, and a second deleteAll would take it too.
/// Signing out can be, and is, until it succeeds.
Future<void> clearKeychainLeftByEarlierInstall({
  FlutterSecureStorage? storage,
  Future<void> Function()? signOutGoogle,
  Future<Directory> Function()? supportDirectory,
}) async {
  final keychain = storage ?? const FlutterSecureStorage();
  final signOut =
      signOutGoogle ??
      () => GoogleSignIn(clientId: googleIosClientId).signOut();
  try {
    final prefs = await SharedPreferences.getInstance();
    await _signOutIfOwed(prefs, signOut);

    final marker = File(
      p.join(
        (await (supportDirectory ?? getApplicationSupportDirectory)()).path,
        _markerFile,
      ),
    );
    final local = marker.existsSync()
        ? (await marker.readAsString()).trim()
        : '';
    // Recorded in both places already: a normal launch, which need not touch
    // the Keychain at all. (A lost flag only costs a Keychain read.)
    if (local.isNotEmpty && (prefs.getBool(_recordedKey) ?? false)) return;

    final kept = await keychain.read(
      key: _keychainIdKey,
      iOptions: passphraseIosOptions,
    );
    if (kept != null && local.isEmpty) {
      try {
        await keychain.deleteAll(iOptions: passphraseIosOptions);
      } on Object catch (e) {
        debugPrint('[Keychain] Could not clear an earlier install: $e');
      }
      await prefs.setBool(_signOutOwedKey, true);
      await _signOutIfOwed(prefs, signOut);
      debugPrint('[Keychain] Cleared what an earlier install left behind');
    }

    final id = local.isNotEmpty ? local : _newId();
    if (local.isEmpty) {
      // Whole or not at all, and on disk before the Keychain hears of it.
      final partial = File('${marker.path}.partial');
      await partial.parent.create(recursive: true);
      await partial.writeAsString(id, flush: true);
      await partial.rename(marker.path);
    }
    if (kept != id) {
      // Deleted first: the Keychain rejects an add over an item that exists.
      await keychain.delete(
        key: _keychainIdKey,
        iOptions: passphraseIosOptions,
      );
      await keychain.write(
        key: _keychainIdKey,
        value: id,
        iOptions: passphraseIosOptions,
      );
    }
    // Only what is really there counts: a write can return and not persist,
    // and an id missing from the Keychain would let the next install inherit
    // this one's passphrase.
    final stored = await keychain.read(
      key: _keychainIdKey,
      iOptions: passphraseIosOptions,
    );
    if (stored == id) await prefs.setBool(_recordedKey, true);
  } on Object catch (e) {
    // Never worth failing startup over; the next launch tries again.
    debugPrint('[Keychain] Could not check for an earlier install: $e');
  }
}

Future<void> _signOutIfOwed(
  SharedPreferences prefs,
  Future<void> Function() signOut,
) async {
  if (!(prefs.getBool(_signOutOwedKey) ?? false)) return;
  try {
    await signOut();
    await prefs.remove(_signOutOwedKey);
  } on Object catch (e) {
    debugPrint('[Keychain] Could not sign out the earlier account yet: $e');
  }
}

String _newId() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
}

/// The install id's file, in the app's container.
const String _markerFile = 'install_id';

/// The install id's copy in the Keychain.
const String _keychainIdKey = 'ghostcopy_install_id';

/// Set once the id is in both places.
const String _recordedKey = 'ghostcopy_install_id_in_keychain';

/// Set while the earlier install's Google account still has to be signed out.
const String _signOutOwedKey = 'ghostcopy_google_sign_out_owed';
