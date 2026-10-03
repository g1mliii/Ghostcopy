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
/// Google Sign-In keeps there.
///
/// A clear that fails is tried once more at once, and if that fails too the
/// new install is not recorded, so the next launch finds the same reinstall
/// and clears again. The cost: a passphrase the user sets in a launch whose
/// clear failed goes with the retry. That takes a Keychain that was readable
/// a moment earlier refusing a delete twice, and the alternative - recording
/// the install anyway - leaves the earlier install's secrets on the phone for
/// good. Pending Google sign-out is flushed to a file before any attempt,
/// so it is retried even if preferences are lost when the app is terminated.
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
    final support =
        await (supportDirectory ?? getApplicationSupportDirectory)();
    final pendingSignOut = File(p.join(support.path, _signOutOwedFile));
    // Preserve pending work recorded by the previous preferences-based
    // implementation, before removing its non-durable flag.
    if (prefs.getBool(_signOutOwedKey) ?? false) {
      if (!pendingSignOut.existsSync()) {
        await _writeFlushed(pendingSignOut, 'pending');
      }
      await prefs.remove(_signOutOwedKey);
    }
    await _signOutIfOwed(pendingSignOut, signOut);

    final marker = File(p.join(support.path, _markerFile));
    final local = marker.existsSync()
        ? (await marker.readAsString()).trim()
        : '';
    // A device restore can bring back the file and preferences without the
    // Keychain copy. Check it on every launch instead of trusting a flag
    // that may have been restored from a backup.
    final kept = await keychain.read(
      key: _keychainIdKey,
      iOptions: passphraseIosOptions,
    );
    if (local.isNotEmpty && kept == local) return;
    if (kept != null && local.isEmpty) {
      // Must persist before clearing or recording the new install: those
      // operations can remove the only other evidence of a reinstall.
      await _writeFlushed(pendingSignOut, 'pending');
      await _signOutIfOwed(pendingSignOut, signOut);
      if (!await _clear(keychain)) {
        // Not recorded: the next launch meets the same reinstall and clears
        // again, rather than leaving the earlier install's secrets for good.
        return;
      }
      debugPrint('[Keychain] Cleared what an earlier install left behind');
    }

    final id = local.isNotEmpty ? local : _newId();
    if (local.isEmpty) {
      // Whole or not at all, and on disk before the Keychain hears of it.
      await _writeFlushed(marker, id);
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
    // The next launch verifies the actual Keychain value again, including
    // when a write returns successfully without persisting the id.
  } on Object catch (e) {
    // Never worth failing startup over; the next launch tries again.
    debugPrint('[Keychain] Could not check for an earlier install: $e');
  }
}

/// Everything GhostCopy keeps in the Keychain - one deleteAll, run by the
/// plugin with no accessibility constraint - tried twice. Whether it went.
Future<bool> _clear(FlutterSecureStorage keychain) async {
  for (var attempt = 1; attempt <= 2; attempt++) {
    try {
      await keychain.deleteAll(iOptions: passphraseIosOptions);
      return true;
    } on Object catch (e) {
      debugPrint(
        '[Keychain] Could not clear an earlier install ($attempt): $e',
      );
    }
  }
  return false;
}

Future<void> _signOutIfOwed(
  File pending,
  Future<void> Function() signOut,
) async {
  if (!pending.existsSync()) return;
  try {
    if ((await pending.readAsString()).trim() == 'done') return;
    await signOut();
    // Keep completion durable too: losing the legacy preferences removal
    // must not revive cleanup and sign out an account added afterwards.
    await _writeFlushed(pending, 'done');
  } on Exception catch (e) {
    debugPrint('[Keychain] Could not sign out the earlier account yet: $e');
  }
}

/// Persist [value] in [file] atomically before committing any related state.
Future<void> _writeFlushed(File file, String value) async {
  final partial = File('${file.path}.partial');
  await partial.parent.create(recursive: true);
  await partial.writeAsString(value, flush: true);
  await partial.rename(file.path);
}

String _newId() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => random.nextInt(256)));
}

/// The install id's file, in the app's container.
const String _markerFile = 'install_id';

/// The install id's copy in the Keychain.
const String _keychainIdKey = 'ghostcopy_install_id';

/// Durable Google sign-out state (`pending` or `done`) in the app's container.
const String _signOutOwedFile = 'google_sign_out_owed';

/// Legacy preferences flag, migrated into [_signOutOwedFile] before retrying.
const String _signOutOwedKey = 'ghostcopy_google_sign_out_owed';
