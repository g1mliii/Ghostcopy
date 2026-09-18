import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../models/exceptions.dart';
import '../encryption_service.dart';
import '../passphrase_sync_service.dart';
import 'keychain_accessibility.dart';
import 'passphrase_sync_service.dart';

/// Payload for a crypto operation running on a background isolate.
///
/// `compute` takes a single argument, which is the only reason these exist.
/// There were four of them - encrypt, decrypt, encrypt-bytes, decrypt-bytes -
/// structurally identical in pairs and differing only in what the field
/// happened to be called.
class _StringCryptoParams {
  const _StringCryptoParams({required this.data, required this.keyBytes});

  /// Plaintext when encrypting, `iv:ciphertext` when decrypting.
  final String data;
  final Uint8List keyBytes;
}

/// The byte-payload counterpart of [_StringCryptoParams], for files and images.
class _BytesCryptoParams {
  const _BytesCryptoParams({required this.data, required this.keyBytes});

  /// Plain bytes when encrypting, `iv + ciphertext` when decrypting.
  final Uint8List data;
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
  }) : // Set on the instance rather than at each call site: every read, write
       // and delete has to agree on how the item is addressed, and nine
       // annotations is nine chances to miss one. Tests inject their own
       // storage and are unaffected.
       _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(iOptions: passphraseIosOptions),
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

  final ValueNotifier<int> _keyRevision = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get keyRevision => _keyRevision;

  /// Replace the loaded key and tell anything caching [isEnabled] about it.
  void _setKeyBytes(Uint8List? bytes) {
    _keyBytes = bytes;
    _keyRevision.value++;
  }

  // Storage keys - user-specific to prevent cross-user passphrase leakage
  String get _passphraseKey => 'encryption_passphrase_$_userId';
  String get _verificationHashKey => 'encryption_verification_hash_$_userId';

  // PBKDF2 algorithm for key derivation is created in-isolate when needed

  // Passphrase security requirements
  static const _minPassphraseLength = 8;

  @override
  Future<void> initialize(String userId) async {
    debugPrint('[EncryptionService] Starting initialization for user: $userId');

    // Already set up for THIS user - nothing to do.
    if (_initialized && _userId == userId) return;

    // Let any in-flight initialization finish BEFORE deciding whether to
    // re-key. The guard below tests _initialized, which is still false while
    // an initialize() is running, so testing it first let a concurrent
    // initialize(userB) skip the re-key, fall into the in-flight branch, and
    // return "successfully" still holding userA's key and _userId - exactly
    // the cross-user corruption the re-key exists to prevent. Loops because
    // another caller can start a fresh init while we are awaiting this one.
    while (_initFuture != null) {
      try {
        await _initFuture;
      } on Object {
        // The caller that started that init handles its own failure; we care
        // only about the resulting state, checked below.
      }
      // That init may have been for our user, in which case we are done.
      if (_initialized && _userId == userId) return;
    }

    // Set up for somebody else. This must re-key, not return early.
    //
    // Signing out signs straight back in anonymously, so that anonymous id is
    // what gets initialised next - with no passphrase and therefore no key.
    // Signing back in then hit the old `if (_initialized) return;` and kept the
    // anonymous id, which broke two things at once: every clip read as
    // undecryptable because no key was loaded, and any passphrase entered
    // afterwards was salted and stored under the ANONYMOUS id (see _deriveKey,
    // which salts with _userId), so recovering encryption produced a key that
    // could never open the user's own clips.
    if (_initialized && _userId != userId) {
      debugPrint(
        '[EncryptionService] User changed ($_userId -> $userId) - re-keying',
      );
      reset();
    }

    _userId = userId;
    final completer = Completer<void>();
    _initFuture = completer.future;

    try {
      // Before the first read, because the keys are user-scoped and the old
      // items are invisible to a read under the new options. On a locked phone
      // this finds nothing and does nothing; the move happens on the next
      // foreground launch, which is the first moment it could.
      if (Platform.isIOS) {
        await migrateKeychainAccessibility(
          storage: _secureStorage,
          keys: [_passphraseKey, _verificationHashKey],
        );
      }

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
      // Store passphrase in platform secure storage.
      //
      // Deleted first, because a write is not reliably an upsert. On iOS the
      // Keychain rejects an add whose item already exists with errSecDuplicateItem
      // (-25299), and that item can be one this app cannot see: Keychain entries
      // survive app deletion, so a delete-and-reinstall leaves the old passphrase
      // behind, and anything that changes how the key is addressed - a plugin
      // default, an accessibility option, an access group - makes the existing
      // item invisible to the read while still blocking the write.
      //
      // The user-visible cost of getting this wrong is total: setPassphrase
      // returns false, the dialog reports "failed to restore" as though the
      // passphrase were wrong, and there is no way out of it from inside the
      // app. delete() is idempotent and costs one call.
      debugPrint('[EncryptionService] Writing passphrase to secure storage...');
      await _secureStorage.delete(key: _passphraseKey);
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
      await _secureStorage.delete(key: _verificationHashKey);
      await _secureStorage.write(
        key: _verificationHashKey,
        value: verificationHash,
      );

      // Derive encryption key
      await _deriveKey(passphrase);

      // Cloud backup is disabled: it encrypted the passphrase with a key
      // derived purely from server-known values, so the server could recover
      // it. Instead of uploading, purge anything an earlier build left behind.
      if (_passphraseSync != null) {
        await _passphraseSync.deleteCloudBackup();
      }

      debugPrint('[EncryptionService] ✅ Encryption enabled successfully');
      return true;
    } on Exception catch (e) {
      debugPrint('[EncryptionService] ❌ Failed to set passphrase: $e');
      debugPrint('[EncryptionService] Stack trace: ${StackTrace.current}');
      // Rethrown rather than folded into `false`. A false return means "that
      // passphrase was not accepted", which tells the user to check it and try
      // again; a secure-storage failure means the device could not keep the
      // passphrase at all, and retrying the same thing cannot help. Reporting
      // the second as the first sends people looking for a lost or corrupted
      // passphrase when nothing is wrong with it.
      throw PassphraseStorageException(e.toString());
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

      // Each delete is attempted independently, and the in-memory key is
      // dropped whatever happens. Sequential awaits meant one failing delete
      // skipped the other and rethrew, leaving the passphrase in memory and
      // half the entries on disk - the worst outcome for something whose whole
      // job is to make the key unavailable. Failing to erase is worth logging,
      // never worth abandoning the rest of the teardown for.
      for (final key in [_passphraseKey, _verificationHashKey]) {
        try {
          await _secureStorage.delete(key: key);
        } on Exception catch (e) {
          debugPrint('[EncryptionService] Could not delete $key: $e');
        }
      }

      // Clear from memory
      _setKeyBytes(null);

      debugPrint('Encryption disabled - passphrase cleared');
    } on Exception catch (e) {
      debugPrint('Failed to clear passphrase: $e');
      _setKeyBytes(null);
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
    _setKeyBytes(null);
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

    // Cloud restore is disabled - see PassphraseSyncService. The backup key was
    // derived entirely from server-known values, so restoring from it (and the
    // upload that fed it) defeated end-to-end encryption. Passphrases now move
    // between devices via the QR/manual transfer flow only.
    //
    // Opportunistically purge any backup an earlier build uploaded, so users
    // stop carrying a server-recoverable passphrase in their user_metadata.
    if (_passphraseSync != null) {
      await _passphraseSync.deleteCloudBackup();
    }

    return false;
  }

  @override
  Future<bool> hasCloudBackup() async {
    if (_passphraseSync == null) return false;
    return _passphraseSync.hasCloudBackup();
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

      _setKeyBytes(Uint8List.fromList(List<int>.from(result)));
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
          _StringCryptoParams(data: plaintext, keyBytes: _keyBytes!),
        );
      }

      // For larger content, run in background isolate to prevent UI blocking
      return await compute(
        _encryptSync,
        _StringCryptoParams(data: plaintext, keyBytes: _keyBytes!),
      );
    } on Exception catch (e) {
      debugPrint('Encryption failed: $e');
      throw EncryptionException('Failed to encrypt content: $e');
    }
  }

  /// Static encryption helper that can run in isolate
  @override
  Future<Uint8List> encryptBytes(Uint8List plain) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }
    // Pass through when encryption is off, so callers do not have to branch.
    final key = _keyBytes;
    if (key == null) return plain;

    // Files are large by definition; always use an isolate to keep the UI and
    // the tray-mode event loop responsive.
    return compute(
      _encryptBytesSync,
      _BytesCryptoParams(data: plain, keyBytes: key),
    );
  }

  @override
  Future<Uint8List> decryptBytes(Uint8List cipher) async {
    if (!_initialized) {
      throw StateError('EncryptionService not initialized');
    }
    final key = _keyBytes;
    if (key == null) return cipher;

    return compute(
      _decryptBytesSync,
      _BytesCryptoParams(data: cipher, keyBytes: key),
    );
  }

  /// Encrypt raw bytes for R2 upload.
  ///
  /// Deliberately NOT the base64 string path: that inflates by ~33%, which is
  /// why files were left unencrypted ("too large, would exceed 10MB limit
  /// after base64"). Encrypting the bytes themselves costs 16 bytes of IV plus
  /// a 16-byte GCM tag - a flat 32 bytes - so a 10MB file stays a 10MB file.
  ///
  /// Layout: [16-byte IV][ciphertext+tag]
  static Uint8List _encryptBytesSync(_BytesCryptoParams params) {
    try {
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final iv = enc.IV.fromSecureRandom(16);

      final encrypted = encrypter.encryptBytes(params.data, iv: iv);

      final out = Uint8List(iv.bytes.length + encrypted.bytes.length)
        ..setRange(0, iv.bytes.length, iv.bytes)
        ..setRange(
          iv.bytes.length,
          iv.bytes.length + encrypted.bytes.length,
          encrypted.bytes,
        );
      return out;
    } on Exception catch (e) {
      throw EncryptionException('Byte encryption failed: $e');
    }
  }

  static Uint8List _decryptBytesSync(_BytesCryptoParams params) {
    try {
      if (params.data.length <= 16) {
        throw EncryptionException('Ciphertext too short to contain an IV');
      }
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      final iv = enc.IV(Uint8List.sublistView(params.data, 0, 16));
      final body = Uint8List.sublistView(params.data, 16);

      return Uint8List.fromList(
        encrypter.decryptBytes(enc.Encrypted(body), iv: iv),
      );
    } on EncryptionException {
      rethrow;
    } on Exception catch (e) {
      throw EncryptionException('Byte decryption failed: $e');
    }
  }

  static String _encryptSync(_StringCryptoParams params) {
    try {
      // Create encrypter with AES GCM mode
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      // Generate random IV for this encryption
      final iv = enc.IV.fromSecureRandom(16);

      // Encrypt the plaintext
      final encrypted = encrypter.encrypt(params.data, iv: iv);

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
          _StringCryptoParams(data: ciphertext, keyBytes: _keyBytes!),
        );
      }

      // For larger content, run in background isolate to prevent UI blocking
      return await compute(
        _decryptSync,
        _StringCryptoParams(data: ciphertext, keyBytes: _keyBytes!),
      );
    } on Exception catch (e) {
      debugPrint('Decryption failed: $e');
      throw EncryptionException('Failed to decrypt content: $e');
    }
  }

  /// Static decryption helper that can run in isolate
  static String _decryptSync(_StringCryptoParams params) {
    try {
      // Create encrypter with AES GCM mode
      final key = enc.Key(params.keyBytes);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));

      // Split IV and ciphertext
      final parts = params.data.split(':');
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
