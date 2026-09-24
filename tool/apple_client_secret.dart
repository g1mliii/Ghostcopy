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

/// The Services ID the browser flow authenticates as. It is also the second
/// entry in the Apple provider's Client IDs in Supabase.
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
