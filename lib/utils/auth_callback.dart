/// Validation for inbound `ghostcopy://` OAuth callback URLs.
///
/// These URLs are untrusted. Windows registers `ghostcopy://` as
/// `"<exe>" "%1"`, so any web page the user visits - or any local process - can
/// put one in front of the app, and a second launch forwards it to the running
/// instance. Handing such a URL straight to gotrue's `getSessionFromUrl` is a
/// login-CSRF primitive: that method skips its PKCE guard whenever the URL
/// carries `access_token`, then persists whatever session the URL described, so
/// the victim's app silently ends up signed into the sender's account and
/// every clip they copy afterwards is written to the sender's rows.
///
/// Kept apart from main.dart so the rules are testable on their own.
library;

/// Whether [uri] is a callback this app asked for.
///
/// Wired into `Supabase.initialize` as `detectSessionInUriPredicate`, because
/// supabase_flutter runs its own deep-link observer (`AppLinks`) that is a
/// second, parallel route to `getSessionFromUrl` - one that does not go through
/// [_handleDeepLinkArgs] at all. Its default heuristic accepts any URI merely
/// carrying `access_token`, `code` or `error` in the query OR the fragment,
/// which is exactly the URL an attacker sends. Validating both routes with the
/// same rules is the point: fixing only the command-line one leaves the app
/// wide open on every platform where AppLinks is the delivery mechanism.
bool isTrustedAuthCallback(Uri uri) =>
    AuthCallbackDecision.evaluate(uri.toString()).isAccepted;

/// Why a callback URL was refused.
enum AuthCallbackRejection {
  /// Not a `ghostcopy://` URL aimed at a callback this app asks for.
  notOurs,

  /// Carried implicit-flow tokens. The app is a PKCE client, so no flow it
  /// starts ever comes back this way.
  implicitTokens,

  /// The provider reported a failure (user declined, expired link).
  providerError,

  /// Well-formed, but carried no authorization code to redeem.
  noCode,
}

/// The only `ghostcopy://` targets the app ever asks Supabase to redirect to.
///
/// `auth-callback` covers Google sign-in and anonymous-to-Google linking;
/// `reset-password` covers the emailed recovery link.
const _allowedCallbackHosts = {'auth-callback', 'reset-password'};

/// Parameters that must never appear: their presence means the URL was not
/// produced by a PKCE flow this app started.
const _implicitTokenKeys = [
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
];

/// What to do with one inbound callback URL.
///
/// Either [code] is non-null and should be redeemed with
/// `exchangeCodeForSession`, or [rejection] explains why nothing should happen.
class AuthCallbackDecision {
  const AuthCallbackDecision._({this.code, this.rejection, this.detail});

  /// Decide what [link] deserves.
  ///
  /// Accepts only a `ghostcopy://` URL aimed at a known callback host and
  /// carrying a PKCE `code`. The code alone is not enough to take over the
  /// session: redeeming it requires the code verifier the app stored when it
  /// started the flow, which a caller that did not start one cannot produce.
  factory AuthCallbackDecision.evaluate(String link) {
    final Uri parsed;
    try {
      parsed = Uri.parse(link);
    } on FormatException {
      return const AuthCallbackDecision._(
        rejection: AuthCallbackRejection.notOurs,
        detail: 'unparseable',
      );
    }

    final uri = _normalize(parsed);

    if (uri.scheme != 'ghostcopy' ||
        !_allowedCallbackHosts.contains(uri.host)) {
      return AuthCallbackDecision._(
        rejection: AuthCallbackRejection.notOurs,
        detail: uri.host.isEmpty ? uri.scheme : uri.host,
      );
    }

    final params = uri.queryParameters;

    // Checked before the error and code branches: a URL carrying these is
    // hostile regardless of what else it says, and should not be given the
    // chance to look like an ordinary failed sign-in.
    for (final key in _implicitTokenKeys) {
      if (params.containsKey(key)) {
        return AuthCallbackDecision._(
          rejection: AuthCallbackRejection.implicitTokens,
          detail: key,
        );
      }
    }

    final error = params['error_description'] ?? params['error'];
    if (error != null) {
      return AuthCallbackDecision._(
        rejection: AuthCallbackRejection.providerError,
        detail: error,
      );
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      return const AuthCallbackDecision._(
        rejection: AuthCallbackRejection.noCode,
      );
    }

    return AuthCallbackDecision._(code: code);
  }

  /// The PKCE authorization code to redeem. Null when the URL was refused.
  final String? code;

  /// Why the URL was refused. Null when it was accepted.
  final AuthCallbackRejection? rejection;

  /// Extra context for the log line - the offending host, parameter, or the
  /// provider's error text. Never the code itself.
  final String? detail;

  bool get isAccepted => code != null;

  /// Fold the fragment into the query.
  ///
  /// Mirrors what gotrue's `getSessionFromUrl` does internally, so that moving
  /// a parameter into the fragment is not a way to slip it past the checks
  /// above while still being read by Supabase.
  static Uri _normalize(Uri uri) {
    final text = uri.toString();
    return Uri.parse(
      uri.hasQuery ? text.replaceAll('#', '&') : text.replaceAll('#', '?'),
    );
  }
}
