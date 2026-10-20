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
