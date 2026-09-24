import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/auth_callback.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

/// Each of these fails against the pre-fix code, which handed every
/// `ghostcopy://` argument straight to `getSessionFromUrl`.
void main() {
  group('AuthCallbackDecision - callbacks the app actually asks for', () {
    test('accepts a PKCE code on the OAuth callback host', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=abc123',
      );

      expect(decision.isAccepted, isTrue);
      expect(decision.code, 'abc123');
      expect(decision.rejection, isNull);
    });

    test('accepts a PKCE code on the password-reset host', () {
      // Arrives by email, possibly days later and after a restart - the code
      // verifier is persisted, so this must keep working.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://reset-password?code=recovery-code',
      );

      expect(decision.isAccepted, isTrue);
      expect(decision.code, 'recovery-code');
    });

    test('accepts a code delivered in the fragment', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback#code=frag-code',
      );

      expect(decision.code, 'frag-code');
    });

    test('keeps the code intact alongside other parameters', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=abc123&state=xyz',
      );

      expect(decision.code, 'abc123');
    });
  });

  group('AuthCallbackDecision - emailed one-time tokens', () {
    // Confirmation links carry token_hash rather than a PKCE code, because a
    // code is only redeemable on the device that began the flow and mail is
    // routinely opened somewhere else. Safe to accept: gotrue checks the token
    // server-side, and holding it already means holding the account's mailbox.
    test('accepts a signup confirmation', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=abc123&type=signup',
      );

      expect(decision.isAccepted, isTrue);
      expect(decision.tokenHash, 'abc123');
      expect(decision.otpType, OtpType.signup);
      expect(decision.code, isNull);
    });

    test('accepts an email change', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=abc123&type=email_change',
      );

      expect(decision.otpType, OtpType.emailChange);
    });

    test('accepts a recovery token', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://reset-password?token_hash=abc123&type=recovery',
      );

      expect(decision.otpType, OtpType.recovery);
    });

    test('accepts a token hash delivered in the fragment', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback#token_hash=abc123&type=signup',
      );

      expect(decision.tokenHash, 'abc123');
    });

    test('refuses a type this app never issues', () {
      // sms and phone_change are real OtpType values, but nothing in the app
      // sends them - so a callback naming one did not come from us.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=abc123&type=sms',
      );

      expect(decision.isAccepted, isFalse);
      expect(decision.rejection, AuthCallbackRejection.unsupportedOtpType);
      expect(decision.detail, 'sms');
    });

    test('refuses a token hash with no type at all', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=abc123',
      );

      expect(decision.rejection, AuthCallbackRejection.unsupportedOtpType);
      expect(decision.detail, 'absent');
    });

    test('still refuses implicit tokens alongside a token hash', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=abc123&type=signup'
        '&access_token=attacker',
      );

      expect(decision.rejection, AuthCallbackRejection.implicitTokens);
    });

    test('never puts the token hash in the log detail', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?token_hash=secret-hash&type=signup',
      );

      expect(decision.detail, isNull);
    });
  });

  group('AuthCallbackDecision - session injection', () {
    test('refuses implicit-flow tokens in the query', () {
      // The attack: gotrue skips its PKCE guard when access_token is present
      // and persists the session, signing the victim into the sender's account.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?access_token=attacker'
        '&refresh_token=attacker&expires_in=3600&token_type=bearer',
      );

      expect(decision.isAccepted, isFalse);
      expect(decision.rejection, AuthCallbackRejection.implicitTokens);
      expect(decision.detail, 'access_token');
    });

    test('refuses implicit-flow tokens hidden in the fragment', () {
      // gotrue folds the fragment into the query before reading it, so a
      // query-only check would miss this.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback#access_token=attacker'
        '&refresh_token=attacker',
      );

      expect(decision.rejection, AuthCallbackRejection.implicitTokens);
    });

    test('refuses a refresh_token even with no access_token', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?refresh_token=attacker',
      );

      expect(decision.rejection, AuthCallbackRejection.implicitTokens);
    });

    test('refuses provider tokens', () {
      for (final key in ['provider_token', 'provider_refresh_token']) {
        final decision = AuthCallbackDecision.evaluate(
          'ghostcopy://auth-callback?$key=attacker',
        );

        expect(
          decision.rejection,
          AuthCallbackRejection.implicitTokens,
          reason: '$key must not be accepted',
        );
      }
    });

    test('refuses tokens even when a code is present too', () {
      // A code alone is harmless, so an attacker would pad the URL with one to
      // look legitimate; the token check has to run first.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=abc123&access_token=attacker',
      );

      expect(decision.isAccepted, isFalse);
      expect(decision.rejection, AuthCallbackRejection.implicitTokens);
    });
  });

  group('AuthCallbackDecision - targets the app never asks for', () {
    test('refuses an unknown host on our own scheme', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://share/42?code=abc123',
      );

      expect(decision.isAccepted, isFalse);
      expect(decision.rejection, AuthCallbackRejection.notOurs);
      expect(decision.detail, 'share');
    });

    test('refuses another scheme', () {
      final decision = AuthCallbackDecision.evaluate(
        'https://auth-callback?code=abc123',
      );

      expect(decision.rejection, AuthCallbackRejection.notOurs);
    });

    test('refuses an unparseable URL', () {
      final decision = AuthCallbackDecision.evaluate('ghostcopy://:::');

      expect(decision.rejection, AuthCallbackRejection.notOurs);
    });
  });

  group('deep-link observer predicate', () {
    // This predicate replaces supabase_flutter's default heuristic, which
    // accepts any URI merely carrying access_token/code/error and hands it to
    // getSessionFromUrl - a second route to the same hole that never touches
    // _handleDeepLinkArgs.
    test('lets a genuine PKCE callback through', () {
      expect(accepts('ghostcopy://auth-callback?code=abc'), isTrue);
      expect(accepts('ghostcopy://reset-password?code=abc'), isTrue);
    });

    test('blocks the URL the default heuristic would have accepted', () {
      expect(
        accepts(
          'ghostcopy://auth-callback?access_token=attacker'
          '&refresh_token=attacker',
        ),
        isFalse,
      );
    });

    test('blocks an access_token hidden in the fragment', () {
      expect(
        accepts('ghostcopy://auth-callback#access_token=attacker'),
        isFalse,
      );
    });

    test('blocks a callback aimed at a host we never registered', () {
      expect(accepts('ghostcopy://share/42?code=abc'), isFalse);
    });
  });

  group('AuthCallbackDecision - nothing to redeem', () {
    test('reports a provider error rather than redeeming', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?error=access_denied'
        '&error_description=User+declined',
      );

      expect(decision.isAccepted, isFalse);
      expect(decision.rejection, AuthCallbackRejection.providerError);
      expect(decision.detail, 'User declined');
      expect(decision.errorCode, 'access_denied');
    });

    test("prefers Supabase's error_code over the OAuth error", () {
      // The message the auth panel shows is chosen from this, so it must not
      // depend on how the description happens to be worded.
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?error=server_error'
        '&error_code=identity_already_exists'
        '&error_description=Identity+is+already+linked+to+another+user',
      );

      expect(decision.errorCode, 'identity_already_exists');
    });

    test('refuses a callback with nothing redeemable', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback',
      );

      expect(decision.rejection, AuthCallbackRejection.noCredential);
    });

    test('refuses an empty code', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=',
      );

      expect(decision.rejection, AuthCallbackRejection.noCredential);
    });

    test('never puts the code in the log detail', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=secret-code',
      );

      expect(decision.detail, isNull);
    });
  });
}

/// The rule `Supabase.initialize` is given as its deep-link predicate.
bool accepts(String link) => AuthCallbackDecision.evaluate(link).isAccepted;
