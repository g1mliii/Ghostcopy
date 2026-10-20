import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/encryption_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// Files moved from package:encrypt's AES-GCM to package:cryptography's for
/// speed. Every file already in storage was written by the old code, and
/// builds already shipped will read what the new code writes - so both
/// directions must agree byte for byte, not just round-trip.
void main() {
  const userId = 'aaaaaaaa-0000-0000-0000-000000000001';
  const passphrase = 'correct horse battery staple';

  late EncryptionService service;
  late Uint8List keyBytes;
  late Uint8List plain;

  setUpAll(() async {
    // The key the service derives: see _deriveKeyIsolate.
    final secretKey =
        await crypto.Pbkdf2(
          macAlgorithm: crypto.Hmac.sha256(),
          iterations: 100000,
          bits: 256,
        ).deriveKey(
          secretKey: crypto.SecretKey(utf8.encode(passphrase)),
          nonce: sha256.convert(utf8.encode(userId)).bytes,
        );
    keyBytes = Uint8List.fromList(await secretKey.extractBytes());

    final storage = _MockSecureStorage();
    when(
      () => storage.read(key: 'encryption_passphrase_$userId'),
    ).thenAnswer((_) async => passphrase);
    service = EncryptionService(secureStorage: storage);
    await service.initialize(userId);

    final random = Random(7);
    plain = Uint8List.fromList(
      List.generate(256 * 1024 + 13, (_) => random.nextInt(256)),
    );
  });

  enc.Encrypter legacy() =>
      enc.Encrypter(enc.AES(enc.Key(keyBytes), mode: enc.AESMode.gcm));

  test('reads a file the old code encrypted', () async {
    final iv = enc.IV.fromSecureRandom(16);
    final body = legacy().encryptBytes(plain, iv: iv).bytes;
    final stored = Uint8List.fromList([...iv.bytes, ...body]);

    expect(await service.decryptBytes(stored), plain);
  });

  test('writes a file the old code can read', () async {
    final stored = await service.encryptBytes(plain);

    final iv = enc.IV(Uint8List.sublistView(stored, 0, 16));
    final body = Uint8List.sublistView(stored, 16);
    expect(legacy().decryptBytes(enc.Encrypted(body), iv: iv), plain);
    // IV + data + tag: the size the upload limit was set against.
    expect(stored.length, plain.length + 32);
  });

  test('round-trips', () async {
    expect(
      await service.decryptBytes(await service.encryptBytes(plain)),
      plain,
    );
  });

  test('a tampered file fails as an EncryptionException', () async {
    final stored = await service.encryptBytes(plain);
    stored[100] ^= 1;

    await expectLater(
      service.decryptBytes(stored),
      throwsA(isA<EncryptionException>()),
    );
  });

  test('a truncated file fails as an EncryptionException', () async {
    await expectLater(
      service.decryptBytes(Uint8List(20)),
      throwsA(isA<EncryptionException>()),
    );
  });
}
