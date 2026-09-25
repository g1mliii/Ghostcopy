// Prints the "Secret Key (for OAuth)" for Supabase's Apple provider.
//
//   dart run tool/apple_client_secret.dart ~/path/to/AuthKey_Y8NRLTKXG3.p8
//
// Apple does not issue that secret: it is a JWT the developer signs with the
// Sign in with Apple key, and Apple caps its lifetime at six months. When it
// lapses, Apple sign-in on desktop (the browser flow) stops working while the
// iPhone, which signs in natively without it, carries on - so the failure is
// easy to miss. Re-run this and paste the new value before the date it prints.
//
// The .p8 is read from disk and never written anywhere. Keep it out of the
// repo: Apple will not let it be downloaded a second time.
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

const _teamId = 'R9TKT8U45R';
const _keyId = 'Y8NRLTKXG3';

/// The Services ID the browser flow authenticates as.
///
/// It must be the FIRST entry in the Apple provider's Client IDs in Supabase.
/// That field is a comma-separated list, and Supabase sends the first entry as
/// `client_id` when it builds the authorize URL; the rest are only accepted
/// audiences for native ID tokens. With the native App ID first, Apple was
/// sent `client_id=com.ghostcopy.ghostcopy` and answered
/// "Invalid client id or web redirect url" - a native App ID cannot carry a
/// web redirect URL, only a Services ID can. It failed on every desktop
/// platform and never on iOS, which uses the native sheet and no client_id at
/// all. Fixed 2026-09-25 by putting `com.ghostcopy.web` first.
///
/// This is also the `sub` of the secret below, so the two only agree when the
/// order is right.
const _servicesId = 'com.ghostcopy.web';

/// Apple's ceiling is 15,777,000 seconds (about 182 days); 180 stays under it.
const _lifetime = Duration(days: 180);

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/apple_client_secret.dart /path/to/AuthKey_$_keyId.p8',
    );
    exit(64);
  }

  final pem = File(args.single).readAsStringSync().trim();
  // Taken before signing, so the printed date is never later than the real
  // `exp` claim.
  final expires = DateTime.now().toUtc().add(_lifetime);
  final secret =
      JWT(
        const <String, dynamic>{},
        issuer: _teamId,
        subject: _servicesId,
        audience: Audience.one('https://appleid.apple.com'),
        header: const {'kid': _keyId},
      ).sign(
        ECPrivateKey(pem),
        algorithm: JWTAlgorithm.ES256,
        expiresIn: _lifetime,
      );

  stdout.writeln(secret);

  stderr
    ..writeln()
    ..writeln('Paste the line above into Supabase > Authentication > Apple >')
    ..writeln('Secret Key (for OAuth). It expires ${expires.toIso8601String()}')
    ..writeln('- regenerate before then.');
}
