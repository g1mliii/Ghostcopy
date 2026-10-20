import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:cryptography/dart.dart' as crypto_dart;
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
  static String _passphraseKeyFor(String? userId) =>
      'encryption_passphrase_$userId';
  static String _verificationHashKeyFor(String? userId) =>
      'encryption_verification_hash_$userId';
  String get _passphraseKey => _passphraseKeyFor(_userId);
  String get _verificationHashKey => _verificationHashKeyFor(_userId);

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
      // items are invisible to a read under the new options. Inaccessible
      // storage must fail initialization so sends cannot fall back to plaintext.
      //
      // It hands back what it read, and that is the value used below rather
      // than a second read of the same key under the same options. The
      // migration has to read the passphrase to decide whether it has work to
      // do, so asking again is pure duplication - on every launch, every
      // re-key, and every push-woken isolate.
      final String? passphrase;
      if (Platform.isIOS) {
        final current = await migrateKeychainAccessibility(
          storage: _secureStorage,
          keys: [_passphraseKey, _verificationHashKey],
        );
        passphrase = current[_passphraseKey];
      } else {
        passphrase = await _secureStorage.read(key: _passphraseKey);
      }
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
    } finally {
      // This future is only a barrier for concurrent callers, which recheck
      // _initialized and retry after a failure. The initiating caller receives
      // the exception directly; duplicating it onto an unobserved future would
      // also report an unhandled asynchronous error.
      completer.complete();
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

      // Read the outgoing value first, so a failed replacement can be undone.
      // This is a replacement whenever a passphrase already exists - a QR
      // import, or entering a different one - and the delete below is not
      // optional, for the reason above. That leaves a window where the only
      // copy of the old passphrase is this local: if the write then failed,
      // nothing restored it, and every clip encrypted under it became
      // unreadable at the next launch. The same window exists in the Keychain
      // accessibility migration and is closed the same way there.
      final previous = await _secureStorage.read(key: _passphraseKey);
      final previousHash = await _secureStorage.read(key: _verificationHashKey);

      // Everything from the first delete to the derived key is one operation,
      // and it either lands whole or is put back. Rolling back only the
      // passphrase write was not enough: the hash write and the key derivation
      // both run after the old passphrase has already been replaced, so a
      // failure there reported failure while the NEW passphrase sat on disk
      // and the OLD key stayed in memory. The next launch would load the new
      // one and every clip encrypted under the old key would be unreadable -
      // the same outcome the rollback exists to prevent, one step later.
      Future<void> restorePrevious() async {
        try {
          await _secureStorage.delete(key: _passphraseKey);
          if (previous != null && previous.isNotEmpty) {
            await _secureStorage.write(key: _passphraseKey, value: previous);
          }
          await _secureStorage.delete(key: _verificationHashKey);
          if (previousHash != null && previousHash.isNotEmpty) {
            await _secureStorage.write(
              key: _verificationHashKey,
              value: previousHash,
            );
          }
          debugPrint(
            '[EncryptionService] Setup failed - restored the previous state',
          );
        } on Exception catch (e) {
          // Nothing further to try, and the original failure is the one worth
          // reporting.
          debugPrint('[EncryptionService] Could not restore: $e');
        }
      }

      try {
        await _secureStorage.delete(key: _passphraseKey);
        if (Platform.isIOS) {
          // Also under the old accessibility. An item left there is invisible to
          // every read this class makes but still collides with the add below,
          // which is the errSecDuplicateItem dead end the dialog used to tell
          // people to reinstall out of - and reinstalling does not help, because
          // Keychain items survive app deletion. initialize()'s migration
          // normally clears it; this covers the case where that was rolled back
          // or never ran, so there is a way out from inside the app.
          await _secureStorage.delete(
            key: _passphraseKey,
            iOptions: legacyPassphraseIosOptions,
          );
        }
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
      } on Exception {
        await restorePrevious();
        rethrow;
      }

      // Outside the rollback: cloud backup is disabled, and this only purges
      // what an earlier build uploaded - it encrypted the passphrase with a key
      // derived purely from server-known values, so the server could recover
      // it. Housekeeping for an obsolete artifact is not a reason to undo a
      // passphrase that stored successfully, nor to report failure for one.
      if (_passphraseSync != null) {
        try {
          await _passphraseSync.deleteCloudBackup();
        } on Exception catch (e) {
          debugPrint('[EncryptionService] Could not purge cloud backup: $e');
        }
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
  Future<void> forgetPassphraseLocally(String userId) async {
    // Keyed by the caller's id, not _userId: whatever this service last
    // loaded - nothing, after a reset or a failed init, or another account -
    // says nothing about which account was just deleted, and the Keychain
    // entry outlives a reinstall on iOS.
    await _deleteStoredPassphrase(userId);
    if (_userId == userId) _setKeyBytes(null);
  }

  /// Delete [userId]'s stored passphrase and verification hash, each
  /// attempted whatever happens to the other. Returns the first failure.
  Future<Exception?> _deleteStoredPassphrase(String? userId) async {
    Exception? undeleted;
    for (final key in [
      _passphraseKeyFor(userId),
      _verificationHashKeyFor(userId),
    ]) {
      try {
        await _secureStorage.delete(key: key);
      } on Exception catch (e) {
        debugPrint('[EncryptionService] Could not delete $key: $e');
        undeleted ??= e;
      }
    }
    return undeleted;
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
      final undeleted = await _deleteStoredPassphrase(_userId);

      // Clear from memory
      _setKeyBytes(null);

      // Reported, not just logged. Returning normally told the settings screen
      // encryption was off while the passphrase was still on disk - and
      // initialize() reads it again on the next launch, so it would come back
      // by itself with the user believing they had turned it off. Both deletes
      // are still attempted and the in-memory key is still dropped first; only
      // the reporting changes.
      if (undeleted != null) {
        throw PassphraseStorageException(undeleted.toString());
      }

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
      _encryptFileBytes,
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
      _decryptFileBytes,
      _BytesCryptoParams(data: cipher, keyBytes: key),
    );
  }

  // compute() entry points. The work is in the top-level functions below,
  // where the formats are described and tests can reach them.
  static Uint8List _encryptFileBytes(_BytesCryptoParams params) =>
      encryptFileBytesSync(params.data, params.keyBytes);

  static Uint8List _decryptFileBytes(_BytesCryptoParams params) =>
      decryptFileBytesSync(params.data, params.keyBytes);

  static String _encryptSync(_StringCryptoParams params) =>
      encryptTextSync(params.data, params.keyBytes);

  static String _decryptSync(_StringCryptoParams params) =>
      decryptTextSync(params.data, params.keyBytes);

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

/// AES-256-GCM for clips and files, through package:cryptography.
///
/// Both formats below were first written by package:encrypt (PointyCastle),
/// and every clip and file already stored is in them. They are standard GCM
/// with a 16-byte nonce, so this reads them and writes what builds still on
/// PointyCastle can read - encryption_formats_test.dart pins that with
/// vectors PointyCastle produced. It replaced PointyCastle for speed: that
/// took 6.8s to decrypt a 5MB file against 0.56s here (AOT, x64).
///
/// The Dart implementation is named rather than AesGcm.with256bits(), which a
/// platform plugin could swap for a native one - and CryptoKit, for one, does
/// not take the 16-byte nonce every stored item already uses.
final _aesGcm = crypto_dart.DartAesGcm(nonceLength: 16);

const int _nonceLength = 16;
const int _tagLength = 16;

/// Encrypt a file for R2 upload: `[16-byte IV][ciphertext][16-byte tag]`.
///
/// Deliberately NOT the base64 text format: that inflates by ~33%, which is
/// why files were once left unencrypted ("too large, would exceed 10MB limit
/// after base64"). This costs a flat 32 bytes, so a 10MB file stays 10MB.
///
/// [nonce] is for tests that compare against fixed vectors; leave it null.
@visibleForTesting
Uint8List encryptFileBytesSync(
  Uint8List plain,
  Uint8List keyBytes, {
  List<int>? nonce,
}) {
  try {
    return _aesGcm
        .encryptSync(
          plain,
          secretKeyData: crypto.SecretKeyData(keyBytes),
          nonce: nonce,
        )
        .concatenation();
  } on Exception catch (e) {
    throw EncryptionException('Byte encryption failed: $e');
  }
}

/// Decrypt what [encryptFileBytesSync] wrote.
@visibleForTesting
Uint8List decryptFileBytesSync(Uint8List stored, Uint8List keyBytes) {
  if (stored.length < _nonceLength + _tagLength) {
    throw EncryptionException('Ciphertext too short to contain an IV');
  }
  try {
    final plain = _aesGcm.decryptSync(
      crypto.SecretBox.fromConcatenation(
        stored,
        nonceLength: _nonceLength,
        macLength: _tagLength,
        copy: false,
      ),
      secretKeyData: crypto.SecretKeyData(keyBytes),
    );
    return plain is Uint8List ? plain : Uint8List.fromList(plain);
  } on Exception catch (e) {
    throw EncryptionException('Byte decryption failed: $e');
  }
}

/// Encrypt a text clip: `base64(IV):base64(ciphertext + tag)`, UTF-8 inside.
///
/// [nonce] is for tests that compare against fixed vectors; leave it null.
@visibleForTesting
String encryptTextSync(
  String plaintext,
  Uint8List keyBytes, {
  List<int>? nonce,
}) {
  try {
    final box = _aesGcm.encryptSync(
      utf8.encode(plaintext),
      secretKeyData: crypto.SecretKeyData(keyBytes),
      nonce: nonce,
    );
    return '${base64Encode(box.nonce)}:'
        '${base64Encode(box.concatenation(nonce: false))}';
  } on Exception catch (e) {
    throw EncryptionException('Encryption failed: $e');
  }
}

/// Decrypt what [encryptTextSync] wrote.
///
/// Malformed UTF-8 is replaced rather than thrown on, as PointyCastle's
/// decrypt did, so a clip that once decoded still does.
@visibleForTesting
String decryptTextSync(String stored, Uint8List keyBytes) {
  try {
    final parts = stored.split(':');
    if (parts.length != 2) {
      throw const FormatException('Invalid encrypted data format');
    }
    final nonce = base64Decode(parts[0]);
    final body = base64Decode(parts[1]);
    if (nonce.length != _nonceLength || body.length < _tagLength) {
      throw const FormatException('Invalid encrypted data format');
    }
    final plain = _aesGcm.decryptSync(
      crypto.SecretBox(
        Uint8List.sublistView(body, 0, body.length - _tagLength),
        nonce: nonce,
        mac: crypto.Mac(Uint8List.sublistView(body, body.length - _tagLength)),
      ),
      secretKeyData: crypto.SecretKeyData(keyBytes),
    );
    return utf8.decode(plain, allowMalformed: true);
  } on FormatException catch (e) {
    throw EncryptionException('Invalid encrypted data format: $e');
  } on Exception catch (e) {
    throw EncryptionException('Decryption failed: $e');
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
