import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/encryption_service.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

/// The stored encryption formats, pinned against output from the library that
/// first wrote them.
///
/// Clips and files were encrypted with package:encrypt (PointyCastle) until it
/// was replaced by package:cryptography for speed. Everything already stored
/// is in PointyCastle's output, and builds still running it will read what
/// this one writes - so the new code must agree with it byte for byte, not
/// merely round-trip. These vectors were produced by PointyCastle with the key
/// bytes 0..31 and the IV bytes 100..115, before it was removed.
void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  final iv = List.generate(16, (i) => 100 + i);

  const text = 'GhostCopy test vector — ünïcödé ✓';
  const textVector =
      'ZGVmZ2hpamtsbW5vcHFycw==:n9ssIpBXSKjL2dnsNKPMEz8SLK/uzwKLUaDX0vc0qKu4d'
      '+oPyesBXZLDn4WBrl3VRx3QDJncYdia';

  final bytes = Uint8List.fromList(List.generate(64, (i) => (i * 7) % 256));
  final bytesVector = base64Decode(
    'ZGVmZ2hpamtsbW5vcHFyc9i0TUT4Nw3pisbrxBOMjgwqBiZFEHx6qm0votNdPNURmyZgOZz'
    'I6dAZEGkoI0qOe4kKGpLNkj5iqJtIghTkMZWBvjvdpeBoE5TA2l77cixc',
  );

  group('text clips', () {
    test('decrypt what PointyCastle wrote', () {
      expect(decryptTextSync(textVector, key), text);
    });

    test('encrypt exactly as PointyCastle did', () {
      expect(encryptTextSync(text, key, nonce: iv), textVector);
    });

    test('a fresh nonce each time', () {
      expect(encryptTextSync(text, key), isNot(encryptTextSync(text, key)));
    });

    test('tampered or malformed input fails as EncryptionException', () {
      final parts = textVector.split(':');
      final body = base64Decode(parts[1])..[0] ^= 1;
      final tampered = '${parts[0]}:${base64Encode(body)}';

      for (final input in [tampered, 'no-separator', 'a:b:c', 'AAAA:AAAA']) {
        expect(
          () => decryptTextSync(input, key),
          throwsA(isA<EncryptionException>()),
          reason: input,
        );
      }
    });
  });

  group('files', () {
    test('decrypt what PointyCastle wrote', () {
      expect(decryptFileBytesSync(bytesVector, key), bytes);
    });

    test('encrypt exactly as PointyCastle did', () {
      expect(encryptFileBytesSync(bytes, key, nonce: iv), bytesVector);
    });

    test('cost a flat 32 bytes over the plaintext', () {
      expect(encryptFileBytesSync(bytes, key).length, bytes.length + 32);
    });

    test('tampered or truncated input fails as EncryptionException', () {
      final tampered = Uint8List.fromList(bytesVector)..[40] ^= 1;
      expect(
        () => decryptFileBytesSync(tampered, key),
        throwsA(isA<EncryptionException>()),
      );
      expect(
        () => decryptFileBytesSync(Uint8List(20), key),
        throwsA(isA<EncryptionException>()),
      );
    });
  });

  // A 4KB file whose GCM counter wraps after block 55. PointyCastle wrote it
  // with the key 0..31 and this nonce, found by searching for one that wraps
  // that early; DartAesGcm alone decrypts everything from byte 880 on to
  // noise, with the tag still verifying. Plaintext is (i * 13) % 256.
  group('a file whose GCM counter wraps', () {
    final wrapStored = base64Decode(
      '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',
    );
    final wrapPlain = Uint8List.fromList(
      List.generate(4096, (i) => (i * 13) % 256),
    );
    final wrapNonce = Uint8List.sublistView(wrapStored, 0, 16);

    test('is found to wrap where it does', () {
      expect(gcmBlocksBeforeCounterWrap(key, wrapNonce, 55), isNull);
      expect(gcmBlocksBeforeCounterWrap(key, wrapNonce, 56), 55);
      expect(gcmBlocksBeforeCounterWrap(key, wrapNonce, 256), 55);
    });

    test('decrypts what PointyCastle wrote', () {
      expect(decryptFileBytesSync(wrapStored, key), wrapPlain);
    });

    test('a tampered tail still fails', () {
      final tampered = Uint8List.fromList(wrapStored)..[16 + 2000] ^= 1;
      expect(
        () => decryptFileBytesSync(tampered, key),
        throwsA(isA<EncryptionException>()),
      );
    });

    test('is never chosen when encrypting', () {
      expect(
        () => encryptFileBytesSync(wrapPlain, key, nonce: wrapNonce),
        throwsArgumentError,
      );
    });
  });

  group('through the service', () {
    const userId = 'aaaaaaaa-0000-0000-0000-000000000001';
    late EncryptionService service;

    setUpAll(() async {
      final storage = _MockSecureStorage();
      when(
        () => storage.read(key: 'encryption_passphrase_$userId'),
      ).thenAnswer((_) async => 'correct horse battery staple');
      service = EncryptionService(secureStorage: storage);
      await service.initialize(userId);
    });

    test('text round-trips on both the direct and the isolate path', () async {
      // Under and over the 5000-character cut-over to compute().
      for (final plain in ['short clip', 'x' * 6000]) {
        expect(await service.decrypt(await service.encrypt(plain)), plain);
      }
    });

    test('files round-trip', () async {
      final random = Random(7);
      final plain = Uint8List.fromList(
        List.generate(256 * 1024 + 13, (_) => random.nextInt(256)),
      );
      expect(
        await service.decryptBytes(await service.encryptBytes(plain)),
        plain,
      );
    });
  });
}
