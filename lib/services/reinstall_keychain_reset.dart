import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'impl/keychain_accessibility.dart';

/// Clears what an earlier install of GhostCopy left in the iOS Keychain.
///
/// Deleting an iOS app deletes its container - settings, the session, caches
/// - but not its Keychain items, so the encryption passphrase outlived the
/// app: still on the phone after the user removed GhostCopy, and handed back
/// to whoever installed it next. This runs on the first launch of a fresh
/// install, before anything reads the Keychain, and removes it.
///
/// "Fresh" is read from the app's own preferences, which iOS deletes with the
/// app: none at all means a new install. An existing install updating to this
/// version has some, so it is marked and left alone - nothing it has stored is
/// touched. A phone restored from a backup gets its preferences back with its
/// Keychain, and is left alone the same way.
///
/// The passphrase is the only Keychain item GhostCopy writes; the session is
/// in preferences, already gone with the app.
Future<void> clearKeychainLeftByEarlierInstall({
  SharedPreferences? preferences,
  Future<void> Function(IOSOptions options)? deleteAll,
}) async {
  try {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    if (prefs.getBool(_checkedKey) ?? false) return;

    // Decided once, and kept until the clear has succeeded: the next launch
    // has preferences of its own and would otherwise take a failed clear for
    // an upgrade, and never try again.
    final fresh =
        (prefs.getBool(_pendingKey) ?? false) || prefs.getKeys().isEmpty;
    if (fresh) {
      await prefs.setBool(_pendingKey, true);
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
    await prefs.setBool(_checkedKey, true);
    await prefs.remove(_pendingKey);
  } on Object catch (e) {
    // Never worth failing startup over; the next launch tries again.
    debugPrint('[Keychain] Could not clear an earlier install: $e');
  }
}

const String _checkedKey = 'keychain_reinstall_checked';
const String _pendingKey = 'keychain_reinstall_clear_pending';
