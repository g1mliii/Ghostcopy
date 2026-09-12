/// Abstract interface for passphrase cloud backup/restore operations.
///
/// CLOUD BACKUP IS DISABLED. The previous implementation derived the backup
/// encryption key from the user's email and user_id with a constant salt
/// compiled into the app, then stored the ciphertext in Supabase
/// `user_metadata`. Every input to that key was known to the server, so the
/// backup offered no protection: anyone with database access or a user's
/// access token could recover the passphrase and decrypt all clipboard
/// history. That defeats the entire point of end-to-end encryption.
///
/// The backup/restore methods are retained so existing callers keep compiling,
/// but they are inert: uploads are refused and restores return nothing.
/// [deleteCloudBackup] remains functional and is used to purge passphrases
/// that earlier builds already uploaded.
///
/// Passphrase transfer between devices happens via the QR/manual flow instead.
abstract class IPassphraseSyncService {
  /// Always false - cloud backup is disabled.
  Future<bool> hasCloudBackup();

  /// Inert. Always returns false without writing anything.
  Future<bool> uploadToCloud(String passphrase);

  /// Inert. Always returns false.
  Future<bool> downloadFromCloud();

  /// Removes any passphrase backup a previous build stored in user_metadata.
  /// Still functional so existing users get their exposed passphrase purged.
  Future<bool> deleteCloudBackup();

  /// Always false - cloud backup is disabled.
  Future<bool> canUseCloudBackup();

  /// Inert. Always returns null.
  Future<String?> getPassphraseFromCloud();
}
