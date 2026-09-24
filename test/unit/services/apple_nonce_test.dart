import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/auth_service.dart';

void main() {
  test('hashed is the SHA-256 of raw, which is what Supabase checks', () {
    final nonce = AuthService.appleNonce(Random(1));
    expect(nonce.hashed, sha256.convert(utf8.encode(nonce.raw)).toString());
  });

  test('raw is 32 characters from the URL-safe set', () {
    final nonce = AuthService.appleNonce(Random(2));
    expect(nonce.raw, hasLength(32));
    expect(nonce.raw, matches(RegExp(r'^[0-9A-Za-z\-._]{32}$')));
  });

  test('every attempt gets a different nonce', () {
    final random = Random.secure();
    final seen = {
      for (var i = 0; i < 100; i++) AuthService.appleNonce(random).raw,
    };
    expect(seen, hasLength(100));
  });
}
