import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
Future<void> clearKeychainLeftByEarlierInstall({
  SharedPreferences? preferences,
  Future<String?> Function()? readKeychainId,
  Future<void> Function(String id)? writeKeychainId,
  Future<void> Function(IOSOptions options)? deleteAll,
}) async {
  const keychain = FlutterSecureStorage(iOptions: passphraseIosOptions);
  try {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final kept = await (readKeychainId ?? () => keychain.read(key: _idKey))();
    final local = prefs.getString(_idKey);
    if (kept != null && kept == local) return;

    if (kept != null && local == null) {
      final delete =
          deleteAll ??
          (options) =>
              const FlutterSecureStorage().deleteAll(iOptions: options);
      // Both: accessibility is part of how an item is addressed, and an
      // earlier install may have written under either.
      for (final options in [
        passphraseIosOptions,
        legacyPassphraseIosOptions,
      ]) {
        await delete(options);
      }
      debugPrint('[Keychain] Cleared what an earlier install left behind');
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

const String _idKey = 'ghostcopy_install_id';

String _newId() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
}
