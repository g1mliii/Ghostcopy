import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../models/exceptions.dart';

/// Where the encryption passphrase used to live.
///
/// `KeychainAccessibility.unlocked` is flutter_secure_storage's default and
/// maps to `kSecAttrAccessibleWhenUnlocked`: readable only while the phone is
/// unlocked. That is wrong for this app specifically, because a push-woken
/// background isolate has to decrypt a clip on a locked phone.
///
/// Spelled out rather than written as `IOSOptions.defaultOptions`, which is the
/// same value today and is what the linter asks for. This constant has to mean
/// "what items were actually written under", a fact about data already on
/// disk; `defaultOptions` means "whatever the package currently defaults to".
/// If the package ever changes that default, the alias would quietly follow it
/// and the migration would start reading from a place nothing was ever stored.
// ignore: use_named_constants
const legacyPassphraseIosOptions = IOSOptions(
  // ignore: avoid_redundant_argument_values
  accessibility: KeychainAccessibility.unlocked,
);

/// Where it lives now: `kSecAttrAccessibleAfterFirstUnlock`, readable once the
/// device has been unlocked at least since boot.
///
/// Deliberately not `first_unlock_this_device`. That variant keeps the item out
/// of encrypted device backups, which is stricter, but this app has no cloud
/// copy of the passphrase by design - `PassphraseSyncService` only deletes
/// what older builds uploaded - so a passphrase that cannot restore onto a new
/// phone means the user's own clips are gone with the old one. iCloud Keychain
/// sync is a separate attribute (`synchronizable`) and stays off either way.
const passphraseIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock,
);

/// Moves existing Keychain items from [legacyPassphraseIosOptions] to
/// [passphraseIosOptions].
///
/// Accessibility is part of how flutter_secure_storage addresses an item, not
/// just a property of it, so changing the constant without this leaves every
/// item already on disk invisible to reads while it still blocks writes. The
/// symptom is a pair of lines that cannot both be true - "No existing
/// passphrase found" followed by errSecDuplicateItem (-25299) - and the cost on
/// a real upgrade is that the user's encrypted clips become permanently
/// unreadable. That happened once here; see tasks/lessons.md, 2026-09-17.
///
/// Returns what each key now holds under [passphraseIosOptions], so the caller
/// does not have to read it again - this already had to read the passphrase to
/// decide whether the migration was needed, and `initialize()` was then issuing
/// an identical read for the value. A null entry means neither location holds
/// an item. Storage and migration failures throw [SecurityException] so callers
/// cannot mistake an inaccessible passphrase for encryption being disabled.
///
/// Safe to call on every launch: it is a no-op once there is nothing left under
/// the old options.
///
/// Callers gate this to iOS. It is not run on macOS - the Keychain there has
/// the same mechanics, but no background isolate wakes on a locked Mac, so the
/// change would be a second migration bought for nothing.
Future<Map<String, String?>> migrateKeychainAccessibility({
  required FlutterSecureStorage storage,
  required Iterable<String> keys,
}) async {
  final current = <String, String?>{};
  SecurityException? failure;
  for (final key in keys) {
    current[key] = null;
    try {
      // Already moved. A generic-password item is identified by service and
      // account, and accessibility is not part of that identity, so the old and
      // new items cannot both exist - finding one here means the migration has
      // run and there is nothing behind it.
      final migrated = await storage.read(
        key: key,
        iOptions: passphraseIosOptions,
      );
      if (migrated != null) {
        current[key] = migrated;
        continue;
      }

      final legacy = await storage.read(
        key: key,
        iOptions: legacyPassphraseIosOptions,
      );
      if (legacy == null || legacy.isEmpty) continue;

      // Delete first, and there is no way around it: SecItemAdd matches on
      // service and account alone, so writing the new item while the old one
      // is present fails as a duplicate. That leaves a window where the only
      // copy of the passphrase is `legacy`, on the stack - hence the restore
      // below rather than a bare rethrow.
      await storage.delete(key: key, iOptions: legacyPassphraseIosOptions);
      try {
        await storage.write(
          key: key,
          value: legacy,
          iOptions: passphraseIosOptions,
        );
      } on Exception {
        await storage.write(
          key: key,
          value: legacy,
          iOptions: legacyPassphraseIosOptions,
        );
        rethrow;
      }

      // Read back before believing it. A write that reports success but does
      // not land would otherwise be indistinguishable from a fresh install on
      // the next launch, and by then `legacy` is gone.
      final check = await storage.read(
        key: key,
        iOptions: passphraseIosOptions,
      );
      if (check != legacy) {
        await storage.write(
          key: key,
          value: legacy,
          iOptions: legacyPassphraseIosOptions,
        );
        debugPrint(
          '[Keychain] $key did not read back after migration - left under the '
          'old accessibility',
        );
        throw SecurityException('Keychain migration could not be verified');
      }

      current[key] = legacy;
      debugPrint('[Keychain] migrated $key to first_unlock');
    } on Exception catch (e) {
      // Finish the remaining keys, but do not return a partial result that
      // initialize() would treat as permission to upload plaintext.
      debugPrint('[Keychain] could not migrate $key: $e');
      failure ??= SecurityException('Could not initialize encryption storage');
    }
  }
  if (failure != null) throw failure;
  return current;
}
