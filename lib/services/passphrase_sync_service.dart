/// Abstract interface for passphrase cloud backup/restore operations
///
/// Provides automatic backup of encryption passphrase to Supabase user metadata
/// for authenticated users (email/password and OAuth). Anonymous users cannot
/// use cloud backup.
///
/// Security:
/// - Passphrase encrypted with derived key (email:user_id)
/// - AES-256-GCM authenticated encryption
/// - Automatic backup when passphrase is set
/// - Automatic restore on login
abstract class IPassphraseSyncService {
  /// Check if cloud backup exists for current user
  Future<bool> hasCloudBackup();

  /// Upload passphrase to cloud (encrypted with derived key)
  /// Returns true if successful, false if user is anonymous or upload failed
  Future<bool> uploadToCloud(String passphrase);

  /// Download and restore passphrase from cloud
  /// Returns true if successful, false if no backup or restore failed
  Future<bool> downloadFromCloud();

  /// Delete cloud backup (when user disables encryption)
  Future<bool> deleteCloudBackup();

  /// Check if current user can use cloud backup (authenticated users only)
  Future<bool> canUseCloudBackup();
}
