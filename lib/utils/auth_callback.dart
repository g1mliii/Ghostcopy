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
/// What is and is not safe to accept, since the three look similar in a URL:
///
///  * `access_token`/`refresh_token` - a session chosen by whoever sent the
///    URL. Accepting one signs the victim into the SENDER's account. Refused.
///  * `code` - a PKCE authorization code, redeemable only with the verifier
///    this process stored when it began the flow. Safe.
///  * `token_hash` - a single-use token mailed to the account's own address and
///    checked server-side by gotrue. Whoever holds it already controls that
///    mailbox, so it grants nothing an attacker could not get directly. Safe,
///    and unlike `code` it survives being opened on another device - which is
///    why email confirmation links use it.
///
/// Kept apart from main.dart so the rules are testable on their own.
library;

import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

/// Why a callback URL was refused.
enum AuthCallbackRejection {
  /// Not a `ghostcopy://` URL aimed at a callback this app asks for.
  notOurs,

  /// Carried implicit-flow tokens. The app is a PKCE client, so no flow it
  /// starts ever comes back this way.
  implicitTokens,

  /// The provider reported a failure (user declined, expired link).
  providerError,

  /// Well-formed, but carried nothing redeemable - no code and no token hash.
  noCredential,

  /// Carried a token hash for a flow this app does not run.
  unsupportedOtpType,
}

/// The only `ghostcopy://` targets the app ever asks Supabase to redirect to.
///
/// `auth-callback` covers Google sign-in, anonymous-to-Google linking, signup
/// confirmation and email change; `reset-password` is retained for recovery
/// links issued before recovery moved to the website (see
/// supabase/email-templates/reset-password.html).
const _allowedCallbackHosts = {'auth-callback', 'reset-password'};

/// Parameters that must never appear: each names a session chosen by the sender
/// rather than proven by the recipient.
const _implicitTokenKeys = [
  'access_token',
  'refresh_token',
  'provider_token',
  'provider_refresh_token',
];

/// Email-link types this app actually issues, mapped from the wire value.
///
/// An allowlist rather than a blanket parse: `OtpType` also covers sms and
/// phone change, which this app never sends, so a callback naming one did not
/// come from us.
const _supportedOtpTypes = <String, OtpType>{
  'signup': OtpType.signup,
  'email_change': OtpType.emailChange,
  'email': OtpType.email,
  'recovery': OtpType.recovery,
};

/// What to do with one inbound callback URL.
///
/// Exactly one of these holds:
///  * [code] is set - redeem it with `exchangeCodeForSession`;
///  * [tokenHash] and [otpType] are set - redeem them with `verifyOTP`;
///  * [rejection] explains why nothing should happen.
class AuthCallbackDecision {
  const AuthCallbackDecision._({
    this.code,
    this.tokenHash,
    this.otpType,
    this.rejection,
    this.detail,
    this.errorCode,
  });

  /// Decide what [link] deserves.
  ///
  /// Accepts a `ghostcopy://` URL aimed at a known callback host that carries
  /// either a PKCE `code` or a `token_hash` of a type this app issues. Neither
  /// is enough to take over the session on its own: a code needs the verifier
  /// this process stored when it began the flow, and a token hash needs control
  /// of the account's mailbox. A URL naming a session directly is refused.
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
        errorCode: params['error_code'] ?? params['error'],
      );
    }

    final code = params['code'];
    if (code != null && code.isNotEmpty) {
      return AuthCallbackDecision._(code: code);
    }

    final tokenHash = params['token_hash'];
    if (tokenHash != null && tokenHash.isNotEmpty) {
      final rawType = params['type'];
      final otpType = _supportedOtpTypes[rawType];
      if (otpType == null) {
        return AuthCallbackDecision._(
          rejection: AuthCallbackRejection.unsupportedOtpType,
          detail: rawType ?? 'absent',
        );
      }
      return AuthCallbackDecision._(tokenHash: tokenHash, otpType: otpType);
    }

    return const AuthCallbackDecision._(
      rejection: AuthCallbackRejection.noCredential,
    );
  }

  /// The PKCE authorization code to redeem. Null when the URL was refused.
  final String? code;

  /// The emailed one-time token to redeem. Null when the URL was refused or
  /// carried a [code] instead.
  final String? tokenHash;

  /// Which email flow [tokenHash] belongs to. Set whenever [tokenHash] is.
  final OtpType? otpType;

  /// Why the URL was refused. Null when it was accepted.
  final AuthCallbackRejection? rejection;

  /// Extra context for the log line - the offending host, parameter, or the
  /// provider's error text. Never the code itself.
  final String? detail;

  /// The machine-readable error of a [AuthCallbackRejection.providerError] -
  /// Supabase's `error_code` (`identity_already_exists`), else the OAuth
  /// `error` (`access_denied`). Stable where [detail]'s wording is not.
  final String? errorCode;

  bool get isAccepted => code != null || tokenHash != null;

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
