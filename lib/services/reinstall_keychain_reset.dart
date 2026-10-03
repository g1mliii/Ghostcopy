import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'google_sign_in_config.dart';
import 'impl/keychain_accessibility.dart';
import 'install_id.dart';

/// Clears what an earlier install of GhostCopy left in the iOS Keychain.
///
/// Deleting an iOS app deletes its container - preferences, the session,
/// caches - but not its Keychain items, so the encryption passphrase
/// outlived the app: still on the phone after the user removed GhostCopy, and
/// handed back to whoever installed it next.
///
/// A reinstall is recognised by the install id ([installIdKey]), kept in
/// preferences and copied into the Keychain. Found in the Keychain but not in
/// preferences means the preferences were deleted while the Keychain was not,
/// and only deleting the app does that - nothing in GhostCopy clears
/// preferences wholesale. Empty preferences alone are not evidence: an
/// install signed out with every setting at its default has none, and still
/// has a passphrase that is its own.
///
/// An install from before this version has no id in the Keychain yet, so it
/// deletes nothing and is recorded; a passphrase left by one of those is not
/// recognised as left over, but every install from here on is.
///
/// A reinstall clears the passphrase, under both accessibility values it may
/// have been written with, and signs out the Google account Google Sign-In
/// keeps in the Keychain. A clear that fails is not retried: the user may set
/// a passphrase this very launch, and a retry could not tell it from the
/// leftover. Something left behind is the lesser loss.
Future<void> clearKeychainLeftByEarlierInstall({
  FlutterSecureStorage? storage,
  Future<void> Function()? signOutGoogle,
}) async {
  final keychain = storage ?? const FlutterSecureStorage();
  final signOut =
      signOutGoogle ??
      () => GoogleSignIn(clientId: googleIosClientId).signOut();
  try {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getString(installIdKey);
    // Recorded in both places already: a normal launch, which need not touch
    // the Keychain at all.
    if (local != null && (prefs.getBool(_recordedKey) ?? false)) return;

    final kept = await keychain.read(
      key: _keychainIdKey,
      iOptions: passphraseIosOptions,
    );
    if (kept != null && local == null) {
      for (final options in [
        passphraseIosOptions,
        legacyPassphraseIosOptions,
      ]) {
        try {
          await keychain.deleteAll(iOptions: options);
        } on Object catch (e) {
          debugPrint('[Keychain] Could not clear an earlier install: $e');
        }
      }
      try {
        await signOut();
      } on Object catch (e) {
        debugPrint('[Keychain] Could not sign out the earlier account: $e');
      }
    }

    // Preferences first. If the Keychain write then fails, the next launch
    // finds the id in preferences only - "not recorded yet", tried again -
    // where the other order would leave it in the Keychain only, which reads
    // as a reinstall and would clear a passphrase that is this install's.
    final id = local ?? await getOrCreateInstallId(prefs);
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
    await prefs.setBool(_recordedKey, true);
  } on Object catch (e) {
    // Never worth failing startup over; the next launch tries again.
    debugPrint('[Keychain] Could not check for an earlier install: $e');
  }
}

/// The install id's copy in the Keychain.
const String _keychainIdKey = 'ghostcopy_install_id';

/// Set once the id is in both places.
const String _recordedKey = 'ghostcopy_install_id_in_keychain';
