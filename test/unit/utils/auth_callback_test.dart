import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/auth_callback.dart';

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

  group('isTrustedAuthCallback - supabase_flutter deep-link observer', () {
    // This predicate replaces supabase_flutter's default heuristic, which
    // accepts any URI merely carrying access_token/code/error and hands it to
    // getSessionFromUrl - a second route to the same hole that never touches
    // _handleDeepLinkArgs.
    test('lets a genuine PKCE callback through', () {
      expect(
        isTrustedAuthCallback(Uri.parse('ghostcopy://auth-callback?code=abc')),
        isTrue,
      );
      expect(
        isTrustedAuthCallback(Uri.parse('ghostcopy://reset-password?code=abc')),
        isTrue,
      );
    });

    test('blocks the URL the default heuristic would have accepted', () {
      expect(
        isTrustedAuthCallback(
          Uri.parse(
            'ghostcopy://auth-callback?access_token=attacker'
            '&refresh_token=attacker',
          ),
        ),
        isFalse,
      );
    });

    test('blocks an access_token hidden in the fragment', () {
      expect(
        isTrustedAuthCallback(
          Uri.parse('ghostcopy://auth-callback#access_token=attacker'),
        ),
        isFalse,
      );
    });

    test('blocks a callback aimed at a host we never registered', () {
      expect(
        isTrustedAuthCallback(Uri.parse('ghostcopy://share/42?code=abc')),
        isFalse,
      );
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
    });

    test('refuses a callback with no code at all', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback',
      );

      expect(decision.rejection, AuthCallbackRejection.noCode);
    });

    test('refuses an empty code', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=',
      );

      expect(decision.rejection, AuthCallbackRejection.noCode);
    });

    test('never puts the code in the log detail', () {
      final decision = AuthCallbackDecision.evaluate(
        'ghostcopy://auth-callback?code=secret-code',
      );

      expect(decision.detail, isNull);
    });
  });
}
