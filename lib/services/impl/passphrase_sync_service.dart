import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../passphrase_sync_service.dart';

/// Cloud passphrase backup - DISABLED.
///
/// The previous implementation encrypted the passphrase with
/// `PBKDF2("<email>:<user_id>", salt: "ghostcopy-passphrase-backup-v1")` and
/// wrote the result to Supabase `user_metadata`. Both key inputs are stored in
/// `auth.users` and the salt was a constant in the shipped binary, so the
/// server (or anyone holding a DB dump or a user access token, which also
/// returns user_metadata) could recompute the key and recover the passphrase -
/// and with it the user's entire clipboard history. The backup provided no
/// confidentiality against the party it was supposed to protect against.
///
/// Rather than re-derive from a secret the server does not hold, the feature is
/// removed. Passphrases transfer between devices via the QR/manual flow.
///
/// [deleteCloudBackup] is deliberately still functional: users of earlier
/// builds have a recoverable passphrase sitting in their user_metadata right
/// now, and it needs to be actively purged rather than merely left behind.
class PassphraseSyncService implements IPassphraseSyncService {
  PassphraseSyncService({SupabaseClient? supabaseClient})
    : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  /// user_metadata key written by earlier builds.
  static const _storageKey = 'encrypted_passphrase_backup';

  @override
  Future<bool> canUseCloudBackup() async => false;

  @override
  Future<bool> hasCloudBackup() async => false;

  @override
  Future<bool> uploadToCloud(String passphrase) async {
    debugPrint(
      '[PassphraseSyncService] Cloud backup is disabled - refusing upload',
    );
    return false;
  }

  @override
  Future<bool> downloadFromCloud() async => false;

  @override
  Future<String?> getPassphraseFromCloud() async => null;

  /// Whether this account still carries a backup written by an earlier build.
  bool hasLegacyBackup() {
    final user = _supabase.auth.currentUser;
    if (user == null || user.isAnonymous) return false;
    return user.userMetadata?[_storageKey] != null;
  }

  @override
  Future<bool> deleteCloudBackup() async {
    final user = _supabase.auth.currentUser;
    if (user == null || user.isAnonymous) return false;

    // Nothing stored - avoid a pointless updateUser round trip.
    if (user.userMetadata?[_storageKey] == null) return false;

    try {
      // GoTrue MERGES user_metadata: PUT /user iterates the supplied map,
      // setting non-null values and deleting ONLY keys whose value is
      // explicitly null. Keys absent from the map are left untouched. Sending a
      // copy of the metadata with the key removed therefore deletes nothing -
      // it must be sent as an explicit null.
      await _supabase.auth.updateUser(
        UserAttributes(data: {_storageKey: null}),
      );

      // Confirm rather than assume. This purge is the ONLY remediation for a
      // passphrase that is already server-recoverable, so a silent failure
      // would leave the user exposed while reporting success.
      final refreshed = await _supabase.auth.getUser();
      final stillPresent = refreshed.user?.userMetadata?[_storageKey] != null;

      if (stillPresent) {
        debugPrint(
          '[PassphraseSyncService] ❌ Legacy passphrase backup STILL PRESENT '
          'after delete attempt - treat this passphrase as compromised and '
          'rotate it',
        );
        return false;
      }

      debugPrint(
        '[PassphraseSyncService] ✓ Purged legacy passphrase backup from '
        'user_metadata',
      );
      return true;
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Failed to purge legacy backup: $e');
      return false;
    }
  }
}
