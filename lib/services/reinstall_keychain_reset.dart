import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'impl/auth_service.dart' show googleIosClientId;
import 'impl/keychain_accessibility.dart';

/// Clears what an earlier install of GhostCopy left in the iOS Keychain.
///
/// Deleting an iOS app deletes its container - preferences, the session,
/// caches - but not its Keychain items, so the encryption passphrase
/// outlived the app: still on the phone after the user removed GhostCopy, and
/// handed back to whoever installed it next.
///
/// A reinstall is recognised by an install id kept in both places. Each
/// install writes one to its preferences and to the Keychain; finding it in
/// the Keychain but not in preferences means the preferences were deleted
/// while the Keychain was not, and only deleting the app does that - nothing
/// in GhostCopy clears preferences wholesale. Empty preferences alone are not
/// evidence: an install signed out with every setting at its default has
/// none, and still has a passphrase that is its own.
///
/// So the first launch of this version on an existing install finds neither,
/// deletes nothing, and records the id. The cost is that a passphrase left by
/// an install from before this version is not recognised as left over; every
/// install from here on is.
///
/// What a reinstall clears: the passphrase, under both accessibility values
/// it may have been written with, and the Google account Google Sign-In
/// keeps in the Keychain, which would otherwise sign the next person in as
/// the last one.
///
/// A clear that fails is not retried. The id is recorded regardless, because
/// the app goes on starting, the user may set a passphrase this very launch,
/// and a retry next time could not tell that one from the leftover. Something
/// left behind is the lesser loss.
Future<void> clearKeychainLeftByEarlierInstall({
  SharedPreferences? preferences,
  Future<String?> Function()? readKeychainId,
  Future<void> Function(String id)? writeKeychainId,
  Future<void> Function(IOSOptions options)? deleteAll,
  Future<void> Function()? signOutGoogle,
}) async {
  const keychain = FlutterSecureStorage(iOptions: passphraseIosOptions);
  try {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final kept = await (readKeychainId ?? () => keychain.read(key: _idKey))();
    final local = prefs.getString(_idKey);
    if (kept != null && kept == local) return;

    if (kept != null && local == null) {
      await _clearEarlierInstall(
        deleteAll ??
            (options) =>
                const FlutterSecureStorage().deleteAll(iOptions: options),
        signOutGoogle ??
            () => GoogleSignIn(clientId: googleIosClientId).signOut(),
      );
    }

    // Preferences first. If the Keychain write then fails, the next launch
    // finds the id in preferences only - "not recorded yet", tried again -
    // where the other order would leave it in the Keychain only, which reads
    // as a reinstall and would clear a passphrase that is this install's.
    final id = local ?? _newId();
    if (local == null) await prefs.setString(_idKey, id);
    await (writeKeychainId ?? (id) => keychain.write(key: _idKey, value: id))(
      id,
    );
  } on Object catch (e) {
    // Never worth failing startup over; the next launch tries again.
    debugPrint('[Keychain] Could not check for an earlier install: $e');
  }
}

Future<void> _clearEarlierInstall(
  Future<void> Function(IOSOptions options) deleteAll,
  Future<void> Function() signOutGoogle,
) async {
  // Each on its own: one failing must not leave the others behind.
  // Accessibility is part of how an item is addressed, so both.
  for (final options in [passphraseIosOptions, legacyPassphraseIosOptions]) {
    try {
      await deleteAll(options);
    } on Object catch (e) {
      debugPrint('[Keychain] Could not clear $options: $e');
    }
  }
  try {
    await signOutGoogle();
  } on Object catch (e) {
    debugPrint('[Keychain] Could not sign out the earlier Google account: $e');
  }
  debugPrint('[Keychain] Cleared what an earlier install left behind');
}

const String _idKey = 'ghostcopy_install_id';

String _newId() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
}
