/// Abstract interface for encryption operations
abstract class IEncryptionService {
  /// Encrypt plaintext content
  Future<String> encrypt(String plaintext);

  /// Decrypt ciphertext content
  Future<String> decrypt(String ciphertext);

  /// Initialize encryption service with user-specific key
  Future<void> initialize(String userId);

  /// Dispose resources
  void dispose();
}
