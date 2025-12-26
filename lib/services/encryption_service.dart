/// Abstract interface for encryption operations
abstract class IEncryptionService {
  /// Check if encryption is enabled (passphrase set)
  Future<bool> isEnabled();

  /// Set encryption passphrase (enables encryption)
  /// Returns true if passphrase meets security requirements
  Future<bool> setPassphrase(String passphrase);

  /// Check if passphrase has been set
  Future<bool> hasPassphrase();

  /// Clear passphrase (disables encryption)
  Future<void> clearPassphrase();

  /// Verify passphrase is correct
  Future<bool> verifyPassphrase(String passphrase);

  /// Export passphrase for QR code transfer (encrypted with one-time key)
  /// Returns base64-encoded encrypted passphrase
  /// Returns null if encryption not enabled
  Future<String?> exportPassphraseForQr();

  /// Import passphrase from QR code data
  /// Returns true if successfully imported and stored
  Future<bool> importPassphraseFromQr(String encryptedData);

  /// Encrypt plaintext content (only if encryption enabled)
  /// Returns plaintext if encryption disabled
  Future<String> encrypt(String plaintext);

  /// Decrypt ciphertext content (only if encryption enabled)
  /// Returns ciphertext unchanged if encryption disabled
  Future<String> decrypt(String ciphertext);

  /// Initialize encryption service with user-specific context
  Future<void> initialize(String userId);

  /// Dispose resources and clear sensitive data from memory
  void dispose();
}
