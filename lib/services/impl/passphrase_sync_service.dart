import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../passphrase_sync_service.dart';

/// Concrete implementation of IPassphraseSyncService
///
/// Provides cloud backup of encryption passphrase to Supabase user metadata.
/// Uses derived key encryption (email:user_id) for automatic backup/restore.
///
/// Security Model:
/// - Passphrase encrypted with AES-256-GCM
/// - Encryption key derived from user's email + user_id via PBKDF2
/// - 100,000 iterations for key derivation (OWASP recommended)
/// - Random IV per backup (stored with encrypted data)
/// - Only works for authenticated users (email/password or OAuth)
/// - Anonymous users cannot use cloud backup
///
/// Threat Model:
/// - Protects against casual snooping by Supabase employees
/// - If Supabase fully compromised (DB + code), backup can be decrypted
/// - Primary protection is E2E encryption of clipboard data itself
/// - Cloud backup is convenience feature for device recovery
class PassphraseSyncService implements IPassphraseSyncService {
  PassphraseSyncService({SupabaseClient? supabaseClient})
      : _supabase = supabaseClient ?? Supabase.instance.client;

  final SupabaseClient _supabase;

  // Key stretching configuration
  static final _kdf = crypto.Pbkdf2(
    macAlgorithm: crypto.Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  // Deterministic salt
  static final _nonce = utf8.encode('ghostcopy-passphrase-backup-v1');

  // Storage identifier
  static const _storageKey = 'encrypted_passphrase_backup';

  @override
  Future<bool> canUseCloudBackup() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return false;

    // Anonymous users cannot use cloud backup
    if (user.isAnonymous) return false;

    // Authenticated users (email/password or OAuth) can use backup
    return true;
  }

  @override
  Future<bool> hasCloudBackup() async {
    if (!await canUseCloudBackup()) return false;

    final user = _supabase.auth.currentUser!;
    final backup = user.userMetadata?[_storageKey];

    return backup != null;
  }

  @override
  Future<bool> uploadToCloud(String passphrase) async {
    if (!await canUseCloudBackup()) {
      debugPrint('[PassphraseSyncService] Cannot upload - user is anonymous');
      return false;
    }

    try {
      final user = _supabase.auth.currentUser!;

      // Derive key material
      final keyMaterial = await _deriveKey(user);

      // Random nonce
      final iv = enc.IV.fromSecureRandom(16);

      // Encrypt
      final key = enc.Key(keyMaterial);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final encrypted = encrypter.encrypt(passphrase, iv: iv);

      // Persist
      await _supabase.auth.updateUser(
        UserAttributes(
          data: {
            _storageKey: {
              'data': encrypted.base64,
              'iv': iv.base64,
              'version': 1,
              'created_at': DateTime.now().toIso8601String(),
            }
          },
        ),
      );

      debugPrint('[PassphraseSyncService] Passphrase backed up to cloud');
      return true;
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Failed to upload backup: $e');
      return false;
    }
  }

  @override
  Future<bool> downloadFromCloud() async {
    if (!await canUseCloudBackup()) {
      debugPrint('[PassphraseSyncService] Cannot download - user is anonymous');
      return false;
    }

    try {
      final user = _supabase.auth.currentUser!;

      // Get stored data
      final backup = user.userMetadata?[_storageKey] as Map<String, dynamic>?;
      if (backup == null) {
        debugPrint('[PassphraseSyncService] No cloud backup found');
        return false;
      }

      // Extract components
      final encryptedData = backup['data'] as String?;
      final ivData = backup['iv'] as String?;

      if (encryptedData == null || ivData == null) {
        debugPrint('[PassphraseSyncService] Invalid backup format');
        return false;
      }

      // Derive key material
      final keyMaterial = await _deriveKey(user);

      // Decrypt
      final key = enc.Key(keyMaterial);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final encrypted = enc.Encrypted.fromBase64(encryptedData);
      final iv = enc.IV.fromBase64(ivData);

      encrypter.decrypt(encrypted, iv: iv);

      debugPrint('[PassphraseSyncService] Passphrase restored from cloud');

      // Return the decrypted passphrase
      // Note: Caller is responsible for storing it via EncryptionService
      return true;
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Failed to download backup: $e');
      return false;
    }
  }

  /// Get the decrypted passphrase from cloud backup
  /// Returns null if no backup or decryption failed
  @override
  Future<String?> getPassphraseFromCloud() async {
    if (!await canUseCloudBackup()) {
      return null;
    }

    try {
      final user = _supabase.auth.currentUser!;

      final backup = user.userMetadata?[_storageKey] as Map<String, dynamic>?;
      if (backup == null) {
        return null;
      }

      final encryptedData = backup['data'] as String?;
      final ivData = backup['iv'] as String?;

      if (encryptedData == null || ivData == null) {
        return null;
      }

      final keyMaterial = await _deriveKey(user);

      final key = enc.Key(keyMaterial);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
      final encrypted = enc.Encrypted.fromBase64(encryptedData);
      final iv = enc.IV.fromBase64(ivData);

      final passphrase = encrypter.decrypt(encrypted, iv: iv);

      return passphrase;
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Failed to get passphrase: $e');
      return null;
    }
  }

  @override
  Future<bool> deleteCloudBackup() async {
    if (!await canUseCloudBackup()) {
      return false;
    }

    try {
      final currentMetadata = _supabase.auth.currentUser?.userMetadata ?? {};
      final updatedMetadata = Map<String, dynamic>.from(currentMetadata)
        ..remove(_storageKey);

      await _supabase.auth.updateUser(
        UserAttributes(data: updatedMetadata),
      );

      debugPrint('[PassphraseSyncService] Cloud backup deleted');
      return true;
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Failed to delete backup: $e');
      return false;
    }
  }

  /// Derive key material from account context
  Future<Uint8List> _deriveKey(User user) async {
    // Build input from available identifiers
    final input = '${user.email ?? user.id}:${user.id}';

    try {
      final secretKey = await _kdf.deriveKey(
        secretKey: crypto.SecretKey(utf8.encode(input)),
        nonce: _nonce,
      );

      return Uint8List.fromList(await secretKey.extractBytes());
    } on Exception catch (e) {
      debugPrint('[PassphraseSyncService] Key derivation failed: $e');
      rethrow;
    }
  }
}
