import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../encryption_service.dart';
import '../passphrase_sync_service.dart';
import 'passphrase_sync_service.dart';

/// Parameters for background encryption
class _EncryptParams {
  const _EncryptParams({required this.plaintext, required this.keyBytes});

  final String plaintext;
  final Uint8List keyBytes;
}

/// Parameters for background decryption
class _DecryptParams {
  const _DecryptParams({required this.ciphertext, required this.keyBytes});

  final String ciphertext;
  final Uint8List keyBytes;
}

/// Concrete implementation of IEncryptionService using optional user passphrase
///
/// Provides client-side end-to-end encryption for clipboard content.
/// **Encryption is optional** - users must set a passphrase to enable it.
///
/// Security Features:
/// - AES-256-GCM authenticated encryption
/// - User-specific encryption keys derived via PBKDF2 (100,000 iterations)
/// - Passphrase stored securely in platform keychain/credential manager
/// - Per-user salt derived from user ID
/// - IV (initialization vector) stored with each encrypted message
/// - Authenticated encryption prevents tampering
/// - Background execution via compute() to prevent main thread blocking
/// - Proper disposal to prevent memory leaks
///
/// Key Derivation:
/// - PBKDF2-HMAC-SHA256 with 100,000 iterations (OWASP recommended)
/// - User passphrase from secure storage (Windows Credential Manager, macOS Keychain, etc.)
/// - Per-user salt = SHA-256(user_id)
/// - Resistant to brute force and rainbow table attacks
///
/// **CRITICAL SECURITY**: No shared secrets - each user controls their own passphrase.
/// If passphrase is lost, encrypted data is permanently irrecoverable.
///
/// **SINGLETON PATTERN**: Use EncryptionService.instance to prevent redundant
/// PBKDF2 key derivation that causes UI jank.
class EncryptionService implements IEncryptionService {
  /// Factory constructor for backwards compatibility and testing
  factory EncryptionService({
    FlutterSecureStorage? secureStorage,
    IPassphraseSyncService? passphraseSyncService,
  }) {
    // For testing with custom dependencies, create a new instance
    if (secureStorage != null || passphraseSyncService != null) {
      return EncryptionService._internal(
        secureStorage: secureStorage,
        passphraseSyncService: passphraseSyncService,
      );
    }
    // Otherwise, return singleton
    return instance;
  }
  // Private constructor for singleton
  EncryptionService._internal({
    FlutterSecureStorage? secureStorage,
    IPassphraseSyncService? passphraseSyncService,
  }) : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
       _passphraseSync = passphraseSyncService;

  // Singleton instance
  // Singleton instance
  static final EncryptionService instance = EncryptionService._internal(
    passphraseSyncService: PassphraseSyncService(),
  );

  final FlutterSecureStorage _secureStorage;
  final IPassphraseSyncService? _passphraseSync;
  Uint8List? _keyBytes;
  String? _userId;
  bool _initialized = false;
  // Guard to prevent concurrent initializations across callers
  Future<void>? _initFuture;

  // Storage keys - user-specific to prevent cross-user passphrase leakage
  String get _passphraseKey => 'encryption_passphrase_$_userId';
  String get _verificationHashKey => 'encryption_verification_hash_$_userId';

  // PBKDF2 algorithm for key derivation is created in-isolate when needed

  // Passphrase security requirements
  static const _minPassphraseLength = 8;

  @override
  Future<void> initialize(String userId) async {
    debugPrint('[EncryptionService] Starting initialization for user: $userId');

    // If already initialized, nothing to do
    if (_initialized) return;

    // If another initialization is in-flight, wait for it
    if (_initFuture != null) {
      await _initFuture;
      return;
    }

    _userId = userId;
    final completer = Completer<void>();
    _initFuture = completer.future;

    try {
      // Try to load and initialize with existing passphrase
      final passphrase = await _secureStorage.read(key: _passphraseKey);
      if (passphrase != null && passphrase.isNotEmpty) {
        debugPrint(
          '[EncryptionService] Found existing passphrase, deriving key...',
        );
        await _deriveKey(passphrase);
      } else {
        debugPrint('[EncryptionService] No existing passphrase found');
      }

      _initialized = true;
      debugPrint(
        '[EncryptionService] ✅ Initialized (encryption enabled: ${_keyBytes != null})',
      );
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _initFuture = null;
    }
  }

  @override
  Future<bool> isEnabled() async {
    return _keyBytes != null;
  }

  @override
  Future<bool> hasPassphrase() async {
    final passphrase = await _secureStorage.read(key: _passphraseKey);
    return passphrase != null && passphrase.isNotEmpty;
  }

  @override
  Future<bool> setPassphrase(String passphrase) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    // Validate passphrase meets security requirements
    if (passphrase.length < _minPassphraseLength) {
      debugPrint(
        'Passphrase too short (minimum $_minPassphraseLength characters)',
      );
      return false;
    }

    try {
      // Store passphrase in platform secure storage
      debugPrint('[EncryptionService] Writing passphrase to secure storage...');
      await _secureStorage.write(key: _passphraseKey, value: passphrase);

      // Verify it was written
      final stored = await _secureStorage.read(key: _passphraseKey);
      debugPrint(
        '[EncryptionService] Passphrase stored: ${stored != null && stored.isNotEmpty}',
      );

      // Create verification hash to validate passphrase later
      final verificationHash = sha256
          .convert(utf8.encode(passphrase))
          .toString();
      await _secureStorage.write(
        key: _verificationHashKey,
        value: verificationHash,
      );

      // Derive encryption key
      await _deriveKey(passphrase);

      // Auto-backup to cloud if available
      if (_passphraseSync != null) {
        final canBackup = await _passphraseSync.canUseCloudBackup();
        if (canBackup) {
          debugPrint('[EncryptionService] Backing up to cloud...');
          await _passphraseSync.uploadToCloud(passphrase);
        }
      }

      debugPrint('[EncryptionService] ✅ Encryption enabled successfully');
      return true;
    } on Exception catch (e) {
      debugPrint('[EncryptionService] ❌ Failed to set passphrase: $e');
      debugPrint('[EncryptionService] Stack trace: ${StackTrace.current}');
      return false;
    }
  }

  @override
  Future<void> clearPassphrase() async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    try {
      // Delete cloud backup if available
      if (_passphraseSync != null) {
        await _passphraseSync.deleteCloudBackup();
      }

      // Clear from secure storage
      await _secureStorage.delete(key: _passphraseKey);
      await _secureStorage.delete(key: _verificationHashKey);

      // Clear from memory
      _keyBytes = null;

      debugPrint('Encryption disabled - passphrase cleared');
    } on Exception catch (e) {
      debugPrint('Failed to clear passphrase: $e');
      rethrow;
    }
  }

  /// Reset encryption state for user switch or sign out
  /// Call this when user logs out or switches accounts
  @override
  void reset() {
    debugPrint('[EncryptionService] Resetting encryption state');
    _initialized = false;
    _userId = null;
    _keyBytes = null;
    _initFuture = null;
    // Note: _passphraseSync is final and cannot be reset
  }

  /// Auto-restore passphrase from cloud backup after Google OAuth sign-in
  /// Returns true if passphrase was restored, false if no backup or restore failed
  @override
  Future<bool> autoRestoreFromCloud() async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    // Check if passphrase already exists locally
    final existingPassphrase = await _secureStorage.read(key: _passphraseKey);
    if (existingPassphrase != null && existingPassphrase.isNotEmpty) {
      debugPrint(
        '[EncryptionService] Passphrase already exists locally, skipping restore',
      );
      return false;
    }

    // Try to get passphrase from cloud backup
    if (_passphraseSync == null) {
      debugPrint('[EncryptionService] PassphraseSync not available');
      return false;
    }

    try {
      final cloudPassphrase = await _passphraseSync.getPassphraseFromCloud();
      if (cloudPassphrase == null || cloudPassphrase.isEmpty) {
        debugPrint('[EncryptionService] No cloud backup found');
        return false;
      }

      debugPrint('[EncryptionService] Found cloud backup, restoring...');

      // Store the passphrase locally
      final success = await setPassphrase(cloudPassphrase);
      if (success) {
        debugPrint('[EncryptionService] ✅ Passphrase auto-restored from cloud');
      } else {
        debugPrint(
          '[EncryptionService] ❌ Failed to restore passphrase from cloud',
        );
      }

      return success;
    } on Exception catch (e) {
      debugPrint('[EncryptionService] Failed to auto-restore from cloud: $e');
      return false;
    }
  }

  @override
  Future<bool> hasCloudBackup() async {
    if (_passphraseSync == null) return false;
    return await _passphraseSync!.hasCloudBackup();
  }

  @override
  Future<bool> verifyPassphrase(String passphrase) async {
    final storedHash = await _secureStorage.read(key: _verificationHashKey);
    if (storedHash == null) return false;

    final inputHash = sha256.convert(utf8.encode(passphrase)).toString();
    return inputHash == storedHash;
  }

  @override
  Future<String?> exportPassphraseForQr() async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    // Get passphrase from secure storage
    final passphrase = await _secureStorage.read(key: _passphraseKey);
    if (passphrase == null || passphrase.isEmpty) {
      return null; // Encryption not enabled
    }

    try {
      // For QR transfer, we encrypt the passphrase with a one-time key
      // The key is embedded in the QR data itself (first 32 bytes)
      // This prevents plaintext passphrase in QR while still allowing transfer

      // Generate random one-time key (32 bytes for AES-256)
      final oneTimeKey = enc.Key.fromSecureRandom(32);

      // Generate random IV
      final iv = enc.IV.fromSecureRandom(16);

      // Encrypt passphrase
      final encrypter = enc.Encrypter(
        enc.AES(oneTimeKey, mode: enc.AESMode.gcm),
      );
      final encrypted = encrypter.encrypt(passphrase, iv: iv);

      // Combine: oneTimeKey + IV + encrypted
      final combined = BytesBuilder()
        ..add(oneTimeKey.bytes)
        ..add(iv.bytes)
        ..add(encrypted.bytes);

      // Return base64-encoded
      return base64Encode(combined.toBytes());
    } on Exception catch (e) {
      debugPrint('Failed to export passphrase: $e');
      return null;
    }
  }

  @override
  Future<bool> importPassphraseFromQr(String encryptedData) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    try {
      // Decode from base64
      final combined = base64Decode(encryptedData);

      // Extract components: key (32) + IV (16) + encrypted (rest)
      if (combined.length < 48) {
        throw const FormatException('Invalid encrypted data length');
      }

      final oneTimeKey = enc.Key(combined.sublist(0, 32));
      final iv = enc.IV(combined.sublist(32, 48));
      final encryptedBytes = combined.sublist(48);

      // Decrypt passphrase
      final encrypter = enc.Encrypter(
        enc.AES(oneTimeKey, mode: enc.AESMode.gcm),
      );
      final encrypted = enc.Encrypted(encryptedBytes);
      final passphrase = encrypter.decrypt(encrypted, iv: iv);

      // Store passphrase using existing method
      final success = await setPassphrase(passphrase);

      // Clear sensitive data from memory
      combined.fillRange(0, combined.length, 0);

      return success;
    } on Exception catch (e) {
      debugPrint('Failed to import passphrase: $e');
      return false;
    }
  }

  /// Derives encryption key from passphrase using PBKDF2
  Future<void> _deriveKey(String passphrase) async {
    if (_userId == null) {
      throw StateError('User ID not set');
    }

    try {
      // Run PBKDF2 in a background isolate to avoid blocking the UI
      final result = await compute(_deriveKeyIsolate, {
        'passphrase': passphrase,
        'userId': _userId!,
        'iterations': 100000,
      });

      _keyBytes = Uint8List.fromList(List<int>.from(result));
      debugPrint('Encryption key derived via PBKDF2 (100k iterations)');
    } on Exception catch (e) {
      debugPrint('Failed to derive key: $e');
      rethrow;
    }
  }

  @override
  Future<String> encrypt(String plaintext) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    // If encryption not enabled, return plaintext
    if (_keyBytes == null) {
      return plaintext;
    }

    try {
      // For small content (<5KB), encrypt directly to avoid isolate overhead
      if (plaintext.length < 5000) {
        return _encryptSync(
          _EncryptParams(plaintext: plaintext, keyBytes: _keyBytes!),
        );
      }

      // For larger content, run in background isolate to prevent UI blocking
      return await compute(
        _encryptSync,
        _EncryptParams(plaintext: plaintext, keyBytes: _keyBytes!),
      );
    } on Exception catch (e) {
      debugPrint('Encryption failed: $e');
      throw EncryptionException('Failed to encrypt content: $e');
    }
  }

  /// Static encryption helper that can run in isolate
  static String _encryptSync(_EncryptParams params) {
    try {
      // Create encrypter with AES GCM mode
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      // Generate random IV for this encryption
      final iv = enc.IV.fromSecureRandom(16);

      // Encrypt the plaintext
      final encrypted = encrypter.encrypt(params.plaintext, iv: iv);

      // Combine IV + encrypted data for storage
      // Format: base64(IV) + ":" + base64(ciphertext)
      return '${iv.base64}:${encrypted.base64}';
    } on Exception catch (e) {
      throw EncryptionException('Encryption failed: $e');
    }
  }

  @override
  Future<String> decrypt(String ciphertext) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }

    // If encryption not enabled, return ciphertext unchanged
    if (_keyBytes == null) {
      return ciphertext;
    }

    try {
      // For small content (estimate based on ciphertext length), decrypt directly
      if (ciphertext.length < 7000) {
        // ~5KB plaintext = ~7KB base64
        return _decryptSync(
          _DecryptParams(ciphertext: ciphertext, keyBytes: _keyBytes!),
        );
      }

      // For larger content, run in background isolate to prevent UI blocking
      return await compute(
        _decryptSync,
        _DecryptParams(ciphertext: ciphertext, keyBytes: _keyBytes!),
      );
    } on Exception catch (e) {
      debugPrint('Decryption failed: $e');
      throw EncryptionException('Failed to decrypt content: $e');
    }
  }

  /// Static decryption helper that can run in isolate
  static String _decryptSync(_DecryptParams params) {
    try {
      // Create encrypter with AES GCM mode
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      // Split IV and ciphertext
      final parts = params.ciphertext.split(':');
      if (parts.length != 2) {
        throw const FormatException('Invalid encrypted data format');
      }

      final iv = enc.IV.fromBase64(parts[0]);
      final encrypted = enc.Encrypted.fromBase64(parts[1]);

      // Decrypt
      return encrypter.decrypt(encrypted, iv: iv);
    } on FormatException catch (e) {
      throw EncryptionException('Invalid encrypted data format: $e');
    } on Exception catch (e) {
      throw EncryptionException('Decryption failed: $e');
    }
  }

  /// Dispose resources and clear sensitive data from memory
  ///
  /// ⚠️ WARNING: This is a SINGLETON service and should NEVER be disposed.
  /// This method exists only for testing purposes with custom instances.
  /// Calling dispose() on the singleton will break encryption for the entire app!
  @override
  void dispose() {
    debugPrint(
      '[EncryptionService] ⚠️ WARNING: Disposing EncryptionService (should only happen in tests!)',
    );

    // Clear sensitive key material from memory
    if (_keyBytes != null) {
      _keyBytes!.fillRange(0, _keyBytes!.length, 0); // Zero out memory
      debugPrint('[EncryptionService] Encryption keys zeroed out in memory');
      _keyBytes = null;
    }
    _userId = null;
    _initialized = false;

    debugPrint(
      '[EncryptionService] ✅ Disposed - all sensitive data cleared from memory',
    );
  }
}

/// Top-level function for PBKDF2 key derivation in isolate
/// Must be top-level or static to avoid serializing the EncryptionService instance
Future<List<int>> _deriveKeyIsolate(Map<String, Object> params) async {
  final passphrase = params['passphrase']! as String;
  final userId = params['userId']! as String;
  final iterations = params['iterations']! as int;

  final saltBytes = sha256.convert(utf8.encode(userId)).bytes;

  final pbkdf2 = crypto.Pbkdf2(
    macAlgorithm: crypto.Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );

  final secretKey = await pbkdf2.deriveKey(
    secretKey: crypto.SecretKey(utf8.encode(passphrase)),
    nonce: saltBytes,
  );

  return secretKey.extractBytes();
}

/// Exception thrown when encryption/decryption operations fail
class EncryptionException implements Exception {
  EncryptionException(this.message);
  final String message;

  @override
  String toString() => 'EncryptionException: $message';
}
