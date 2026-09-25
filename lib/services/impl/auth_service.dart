import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../repositories/clipboard_repository.dart';
import '../auth_service.dart';
import '../device_service.dart';
import '../encryption_service.dart';
import 'encryption_service.dart';
import 'pkce_verifier_store.dart';

/// Concrete implementation of IAuthService using Supabase Auth
class AuthService implements IAuthService {
  AuthService({
    SupabaseClient? client,
    this._deviceService,
    this._googleSignIn,
    Future<String?> Function()? appleReauthorize,
    IEncryptionService? encryptionService,
    IClipboardRepository? clipboardRepository,
    this._pkceStore,
  }) : _client = client ?? Supabase.instance.client,
       _appleReauthorize = appleReauthorize ?? _nativeAppleAuthorizationCode,
       _encryptionOverride = encryptionService,
       _repositoryOverride = clipboardRepository;

  // The app-wide singletons unless a test supplies its own: both reach for
  // the global Supabase instance, which isolated tests never start.
  final IEncryptionService? _encryptionOverride;
  final IClipboardRepository? _repositoryOverride;
  IEncryptionService get _encryption =>
      _encryptionOverride ?? EncryptionService.instance;
  IClipboardRepository get _repository =>
      _repositoryOverride ?? ClipboardRepository.instance;

  /// Asks Apple for a fresh authorization code before account deletion; null
  /// when the user cancels. Injectable because the native sheet cannot run in
  /// tests.
  final Future<String?> Function() _appleReauthorize;

  /// Where Supabase sends the browser back to after Google sign-in.
  ///
  /// A web page rather than `ghostcopy://` directly: the OS takes a custom
  /// scheme without navigating the tab, so the browser was left spinning on
  /// Supabase's interstitial forever even though the app had signed in. The
  /// page forwards the PKCE code to `ghostcopy://auth-callback` and tells the
  /// user they can close it. Recovery already works this way.
  ///
  /// Must stay in Supabase's redirect allowlist, or the provider refuses the
  /// redirect and sign-in fails outright.
  static const _oauthRedirect = 'https://ghostcopy.app/auth-callback';

  final SupabaseClient _client;
  final IDeviceService? _deviceService;

  /// The storage Supabase was given for PKCE verifiers - see
  /// [PkceVerifierStore]. Without it an abandoned browser sign-in cannot
  /// forget its verifier.
  final PkceVerifierStore? _pkceStore;
  bool _initialized = false;

  // Lazy GoogleSignIn instance for native mobile auth (reused to prevent memory leaks)
  GoogleSignIn? _googleSignIn;

  // OPTIMIZED: Reuse secure random instance (not created on every token generation!)
  // Performance: Saves ~0.5-2ms per token (5-10× faster)
  static final Random _secureRandom = Random.secure();

  @override
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[AuthService] Already initialized, skipping');
      return;
    }

    debugPrint('[AuthService] 🚀 Starting initialization...');

    // Sign in anonymously if no user exists
    if (_client.auth.currentUser == null) {
      debugPrint('[AuthService] No current user, signing in anonymously...');
      try {
        final response = await _client.auth.signInAnonymously();
        // Checked, not assumed. A response that carries no session is not an
        // AuthException and does not throw, so without this `initialize`
        // returned as if it had signed in and left `currentUser` null - which
        // surfaced downstream as a fatal StateError from
        // registerCurrentDevice rather than as the auth failure it was.
        if (response.session == null) {
          throw AuthException(
            'Anonymous sign-in returned no session',
          );
        }
        debugPrint('[AuthService] ✅ Signed in anonymously');
      } on AuthException catch (e) {
        debugPrint(
          '[AuthService] ❌ Failed to sign in anonymously: ${e.message}',
        );
        rethrow;
      }
    } else {
      debugPrint('[AuthService] Already signed in');
    }

    // Re-read AFTER the sign-in above. This used to reuse a `currentUser`
    // captured before it, which is null in exactly the case that branch exists
    // for - a fresh install - so the `!= null` guard below was false and
    // EncryptionService was never initialized at all for that whole session.
    final currentUser = _client.auth.currentUser;

    // Initialize EncryptionService with current user
    if (currentUser != null) {
      await EncryptionService.instance.initialize(currentUser.id);

      // Auto-restore passphrase from cloud if authenticated and no local passphrase
      if (!currentUser.isAnonymous) {
        await EncryptionService.instance.autoRestoreFromCloud();
      }
    }

    _initialized = true;
  }

  @override
  User? get currentUser => _client.auth.currentUser;

  @override
  bool get isAnonymous => _client.auth.currentUser?.isAnonymous ?? true;

  @override
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  @override
  Future<AuthResponse> signUpWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
        captchaToken: captchaToken,
      );
      debugPrint('[AuthService] Sign up successful');
      return response;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Sign up failed: ${e.message}');
      rethrow;
    }
  }

  @override
  Future<AuthResponse> signInWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    try {
      final response = await _switchAccount(
        () => _client.auth.signInWithPassword(
          email: email,
          password: password,
          captchaToken: captchaToken,
        ),
      );
      debugPrint('[AuthService] Sign in successful');
      return response;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Sign in failed: ${e.message}');
      rethrow;
    }
  }

  @override
  Future<bool> signInWithGoogle() async {
    try {
      // Use native Google Sign-In for iOS and Android
      if (_googleSignIn != null || Platform.isIOS || Platform.isAndroid) {
        return await _nativeGoogleSignIn();
      }

      return await _webOAuthSignIn(OAuthProvider.google);
    } on BrowserSignInException {
      // The provider's own error, for the auth panel to show.
      rethrow;
    } on Exception catch (e) {
      debugPrint('[AuthService] Google sign in error: $e');
      return false;
    }
  }

  /// Sign in through the browser: desktop for every provider, and Android for
  /// Apple, which has no native sheet there.
  ///
  /// Supabase sends the browser back to [_oauthRedirect], a page on the site
  /// that forwards the PKCE code to `ghostcopy://auth-callback`; the app
  /// redeems it there (desktop via _handleDeepLinkArgs, Android via
  /// supabase_flutter's own link observer). Both check the URL with
  /// AuthCallbackDecision first.
  Future<bool> _webOAuthSignIn(OAuthProvider provider) async {
    // Launching a browser is not a completed sign-in. Keep the old session
    // until the callback has actually installed the new one.
    final previous = _client.auth.currentSession;
    final deviceId = _deviceService?.getCurrentDeviceId();
    try {
      final signedIn = await _viaBrowser(
        launch: () => _client.auth.signInWithOAuth(
          provider,
          redirectTo: kIsWeb ? null : _oauthRedirect,
          authScreenLaunchMode: kIsWeb
              ? LaunchMode.platformDefault
              : LaunchMode.externalApplication,
        ),
        isDone: (session) => session.user.id != previous?.user.id,
      );
      if (!signedIn) return false;
      // Only on this path. It used to hang off a listener that stayed armed
      // after the wait gave up, so a browser sign-in finished after the
      // timeout still switched accounts and deleted the guest's clips while
      // the panel had already reported failure.
      await _finishAccountSwitch(previous, deviceId);
      debugPrint(
        '[AuthService] ${provider.name} sign in completed (web OAuth)',
      );
      return true;
    } on AuthException catch (e) {
      debugPrint('[AuthService] ${provider.name} sign in failed: ${e.message}');
      return false;
    }
  }

  /// How long a browser sign-in may take before it counts as abandoned.
  static const _browserAuthTimeout = Duration(minutes: 3);

  /// The browser sign-in being waited on, if any. Completed early by
  /// [cancelBrowserSignIn] and [failBrowserSignIn].
  Completer<bool>? _browserAuth;

  @override
  bool get isAwaitingBrowserSignIn => _browserAuth != null;

  @override
  void cancelBrowserSignIn() {
    final pending = _browserAuth;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  @override
  void failBrowserSignIn(String message) {
    final pending = _browserAuth;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(BrowserSignInException(message));
    }
  }

  /// Open the browser with [launch] and wait for its callback.
  ///
  /// Listens before the browser opens, so a quick callback is not missed, and
  /// stops waiting at once if the browser never opened.
  Future<bool> _viaBrowser({
    required Future<bool> Function() launch,
    required bool Function(Session session) isDone,
  }) async {
    final result = awaitBrowserSession(isDone);
    var launched = false;
    try {
      launched = await launch();
    } finally {
      if (!launched) cancelBrowserSignIn();
    }
    return result;
  }

  /// Resolves true once the browser flow's callback has installed a session
  /// that satisfies [isDone]; false if none does within [timeout] or the user
  /// cancels. Throws [BrowserSignInException] when the provider redirected
  /// back with an error.
  ///
  /// signInWithOAuth and linkIdentity return as soon as the browser opens.
  /// Reporting that as success let the auth panel run its post-login work
  /// against the old guest session and close - so the realtime subscription
  /// stayed on the guest, and cancelling in the browser looked like success.
  ///
  /// A flow that ends any way but success forgets its PKCE verifier, so a
  /// callback arriving after the wait gave up can no longer be redeemed. The
  /// alternative is an account switch nobody is waiting for: the panel has
  /// already said it failed and will not move the realtime subscription.
  @visibleForTesting
  Future<bool> awaitBrowserSession(
    bool Function(Session session) isDone, {
    Duration timeout = _browserAuthTimeout,
  }) async {
    // A new flow replaces any older one still waiting.
    cancelBrowserSignIn();
    final outcome = Completer<bool>();
    _browserAuth = outcome;

    // Checks the live session rather than the event's: onAuthStateChange is
    // an unbounded ReplaySubject, so a new subscriber is first handed every
    // event this process has seen, including sign-ins of other accounts that
    // would otherwise read as done.
    final subscription = _client.auth.onAuthStateChange.listen((_) {
      final live = _client.auth.currentSession;
      if (live != null && isDone(live) && !outcome.isCompleted) {
        outcome.complete(true);
      }
    }, onError: (Object _) {});
    final timer = Timer(timeout, () {
      if (outcome.isCompleted) return;
      debugPrint('[AuthService] Browser sign-in did not complete in time');
      outcome.complete(false);
    });

    var succeeded = false;
    try {
      return succeeded = await outcome.future;
    } finally {
      timer.cancel();
      unawaited(subscription.cancel());
      if (identical(_browserAuth, outcome)) _browserAuth = null;
      if (!succeeded) await _forgetCodeVerifier();
    }
  }

  Future<void> _forgetCodeVerifier() async {
    try {
      await _pkceStore?.forget();
    } on Object catch (e) {
      debugPrint('[AuthService] Could not drop the PKCE verifier: $e');
    }
  }

  /// Link [provider] to the anonymous user through the browser, preserving
  /// user_id and clipboard data. Same return path as [_webOAuthSignIn].
  Future<bool> _webOAuthLink(OAuthProvider provider) async {
    try {
      // Linking keeps the user id; it is done when the account stops being a
      // guest.
      final userId = _client.auth.currentUser?.id;
      final linked = await _viaBrowser(
        launch: () => _client.auth.linkIdentity(
          provider,
          redirectTo: kIsWeb ? null : _oauthRedirect,
          authScreenLaunchMode: kIsWeb
              ? LaunchMode.platformDefault
              : LaunchMode.externalApplication,
        ),
        isDone: (session) =>
            session.user.id == userId && !session.user.isAnonymous,
      );
      debugPrint('[AuthService] ${provider.name} identity link: $linked');
      return linked;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Link ${provider.name} failed: ${e.message}');
      return false;
    }
  }

  /// Native Google Sign-In for iOS and Android
  Future<bool> _nativeGoogleSignIn() async {
    // Web Client ID (registered in Supabase Dashboard)
    const webClientId =
        '415247311354-a52tbjsq9gvs3vcmt41ig20ugbhfcijg.apps.googleusercontent.com';
    // iOS Client ID (for iOS only)
    const iosClientId =
        '415247311354-g70ehvo2askqsrp85qlhjg9ffmagroti.apps.googleusercontent.com';

    final scopes = ['email', 'profile'];

    // Reuse GoogleSignIn instance to prevent memory leaks
    _googleSignIn ??= GoogleSignIn(
      serverClientId: webClientId,
      // For iOS: specify clientId explicitly
      // For Android: omit clientId - automatically uses google-services.json
      clientId: Platform.isIOS ? iosClientId : null,
      scopes: scopes,
    );
    final googleSignIn = _googleSignIn!;

    try {
      // Attempt lightweight authentication (silent sign-in if previously signed in)
      final googleUser = await googleSignIn.signInSilently();
      final account = googleUser ?? await googleSignIn.signIn();

      if (account == null) {
        debugPrint('[AuthService] Google sign in cancelled by user');
        return false;
      }

      // Get authentication details
      final googleAuth = await account.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) {
        debugPrint('[AuthService] No ID token found from Google');
        return false;
      }

      // Sign in to Supabase with Google credentials
      await _switchAccount(
        () => _client.auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: accessToken,
        ),
      );

      debugPrint('[AuthService] ✅ Native Google sign in successful');
      return true;
    } on Exception catch (e) {
      debugPrint('[AuthService] ❌ Native Google sign in failed: $e');
      return false;
    }
  }

  @override
  Future<bool> signInWithApple() async {
    try {
      // iOS and macOS have the native sheet (Face ID / Touch ID and the
      // device's Apple ID, no browser). Windows and Android get the browser
      // flow, so someone who signed up on an iPhone with Hide My Email still
      // has a way into the account on every device.
      if (!_hasNativeAppleSignIn) {
        return await _webOAuthSignIn(OAuthProvider.apple);
      }

      final credential = await _appleCredential();
      if (credential == null) return false;

      await _switchAccount(
        () => _client.auth.signInWithIdToken(
          provider: OAuthProvider.apple,
          idToken: credential.idToken,
          nonce: credential.nonce,
        ),
      );

      debugPrint('[AuthService] ✅ Apple sign in successful');
      return true;
    } on BrowserSignInException {
      // The provider's own error, for the auth panel to show.
      rethrow;
    } on Exception catch (e) {
      debugPrint('[AuthService] ❌ Apple sign in failed: $e');
      return false;
    }
  }

  @override
  Future<bool> linkAppleIdentity() async {
    if (!isAnonymous) {
      throw Exception('User is already authenticated with a permanent account');
    }
    try {
      if (!_hasNativeAppleSignIn) {
        return await _webOAuthLink(OAuthProvider.apple);
      }

      final credential = await _appleCredential();
      if (credential == null) return false;

      // Link to the current session rather than signing into a different user.
      await _client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.apple,
        idToken: credential.idToken,
        nonce: credential.nonce,
      );

      debugPrint('[AuthService] ✅ Apple identity linked (user_id preserved)');
      return true;
    } on BrowserSignInException {
      // The provider's own error, for the auth panel to show.
      rethrow;
    } on Exception catch (e) {
      debugPrint('[AuthService] ❌ Apple identity linking failed: $e');
      return false;
    }
  }

  /// Apple's own sign-in sheet, used on iOS, where it authenticates as the
  /// bundle ID, `com.ghostcopy.ghostcopy` - the first Client ID on Supabase's
  /// Apple provider.
  ///
  /// Not on macOS, although the sheet exists there: it needs the
  /// com.apple.developer.applesignin entitlement, and Apple will not issue a
  /// Developer ID provisioning profile that carries it - the export of the
  /// notarized build fails outright. The Mac signs in with Apple through the
  /// browser instead, the same flow as Google on the Mac and everything on
  /// Windows.
  static bool get _hasNativeAppleSignIn => Platform.isIOS;

  /// Ask the OS for an Apple ID credential. Null when the user cancels.
  ///
  /// Only the email scope: the app never shows a name, and Apple would hand
  /// it over only on the first authorization anyway.
  Future<({String idToken, String nonce})?> _appleCredential() async {
    final nonce = appleNonce(_secureRandom);
    final credential = await _requestAppleCredential(
      scopes: const [AppleIDAuthorizationScopes.email],
      nonce: nonce.hashed,
    );
    if (credential == null) return null;
    final idToken = credential.identityToken;
    if (idToken == null) {
      debugPrint('[AuthService] No identity token from Apple');
      return null;
    }
    return (idToken: idToken, nonce: nonce.raw);
  }

  /// The native Apple sheet. Null when the user cancels it; any other
  /// failure is rethrown.
  static Future<AuthorizationCredentialAppleID?> _requestAppleCredential({
    required List<AppleIDAuthorizationScopes> scopes,
    String? nonce,
  }) async {
    try {
      return await SignInWithApple.getAppleIDCredential(
        scopes: scopes,
        nonce: nonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) rethrow;
      debugPrint('[AuthService] Apple sheet cancelled by user');
      return null;
    }
  }

  /// A fresh nonce for one Sign in with Apple attempt.
  ///
  /// Apple is given the SHA-256 of [raw] and embeds it in the identity token;
  /// Supabase is given [raw] and checks the token carries its hash. A token
  /// lifted from some other sign-in therefore cannot be replayed here.
  @visibleForTesting
  static ({String raw, String hashed}) appleNonce(Random random) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final raw = String.fromCharCodes(
      List<int>.generate(
        32,
        (_) => charset.codeUnitAt(random.nextInt(charset.length)),
      ),
    );
    return (raw: raw, hashed: sha256.convert(utf8.encode(raw)).toString());
  }

  @override
  Future<UserResponse> upgradeWithEmail(
    String email,
    String password, {
    String? captchaToken,
  }) async {
    if (!isAnonymous) {
      throw Exception('User is already authenticated with a permanent account');
    }

    try {
      // First, update the user's email
      // This will fail if the email is already in use
      // Note: captchaToken not needed for updateUser - user is already authenticated
      final userResponse = await _client.auth.updateUser(
        UserAttributes(email: email, password: password),
      );

      debugPrint(
        '[AuthService] Upgraded anonymous user to: $email (user_id preserved)',
      );
      return userResponse;
    } on AuthException catch (e) {
      if (e.message.contains('already registered') ||
          e.message.contains('already exists')) {
        debugPrint('[AuthService] Email already registered: $email');
        throw Exception('Email already registered. Please sign in instead.');
      }
      debugPrint('[AuthService] Upgrade failed: ${e.message}');
      rethrow;
    }
  }

  @override
  Future<bool> linkGoogleIdentity() async {
    if (!isAnonymous) {
      throw Exception('User is already authenticated with a permanent account');
    }

    try {
      // Use native Google Sign-In for iOS and Android
      if (_googleSignIn != null || Platform.isIOS || Platform.isAndroid) {
        return await _nativeLinkGoogleIdentity();
      }

      // Desktop: link through the browser, preserving user_id and clips
      return await _webOAuthLink(OAuthProvider.google);
    } on BrowserSignInException {
      // The provider's own error, for the auth panel to show.
      rethrow;
    } on Exception catch (e) {
      debugPrint('[AuthService] Link Google identity error: $e');
      return false;
    }
  }

  /// Native Google Identity Linking for iOS and Android
  Future<bool> _nativeLinkGoogleIdentity() async {
    // Web Client ID (registered in Supabase Dashboard)
    const webClientId =
        '415247311354-a52tbjsq9gvs3vcmt41ig20ugbhfcijg.apps.googleusercontent.com';
    // iOS Client ID (for iOS only)
    const iosClientId =
        '415247311354-g70ehvo2askqsrp85qlhjg9ffmagroti.apps.googleusercontent.com';

    final scopes = ['email', 'profile'];

    // Reuse GoogleSignIn instance to prevent memory leaks
    _googleSignIn ??= GoogleSignIn(
      serverClientId: webClientId,
      // For iOS: specify clientId explicitly
      // For Android: omit clientId - automatically uses google-services.json
      clientId: Platform.isIOS ? iosClientId : null,
      scopes: scopes,
    );
    final googleSignIn = _googleSignIn!;

    try {
      final account = await googleSignIn.signIn();

      if (account == null) {
        debugPrint('[AuthService] Google sign in cancelled by user');
        return false;
      }

      // Get authentication details
      final googleAuth = await account.authentication;
      final idToken = googleAuth.idToken;
      final accessToken = googleAuth.accessToken;

      if (idToken == null) {
        debugPrint('[AuthService] No ID token found from Google');
        return false;
      }

      // Link to the current session rather than signing into a different user.
      await _client.auth.linkIdentityWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );

      debugPrint(
        '[AuthService] ✅ Native Google identity linked (user_id preserved)',
      );
      return true;
    } on Exception catch (e) {
      debugPrint('[AuthService] ❌ Native Google identity linking failed: $e');
      return false;
    }
  }

  @override
  Future<({String tokenHash, String pin})> generateMobileLinkToken() async {
    final userId = currentUser?.id;
    if (userId == null) {
      throw Exception('User must be authenticated to generate link token');
    }

    // Generate a cryptographically secure random token
    // OPTIMIZED: Use shared static secure random instance
    final randomBytes = List<int>.generate(
      32,
      (_) => _secureRandom.nextInt(256),
    );
    final tokenData = '$userId:${base64.encode(randomBytes)}';
    final bytes = utf8.encode(tokenData);
    final hash = sha256.convert(bytes).toString();

    // 6-digit PIN shown on this device's screen and typed on the receiving
    // one. Only its SHA-256 is stored, and the server matches it as part of
    // consuming the token - so a photographed QR alone cannot link a device,
    // and a wrong PIN does not burn the single-use token.
    final pin = (_secureRandom.nextInt(900000) + 100000).toString();
    final pinHash = sha256.convert(utf8.encode(pin)).toString();

    // Token expires in 5 minutes. UTC, not local.
    //
    // toIso8601String() on a LOCAL DateTime emits no timezone suffix, and
    // Postgres reads a naive timestamp as UTC - so the stored expiry was off by
    // the device's offset. East of UTC that pushed expires_at past
    // created_at + 10 minutes and the mobile_link_tokens_max_ttl CHECK rejected
    // the insert outright; west of UTC the token was already expired when
    // written. QR linking only worked within a few minutes of UTC.
    final expiresAt = DateTime.now()
        .toUtc()
        .add(const Duration(minutes: 5))
        .toIso8601String();

    // Store token in database
    try {
      await _client.from('mobile_link_tokens').insert({
        'user_id': userId,
        'token': hash,
        'pin_hash': pinHash,
        'expires_at': expiresAt,
      });

      debugPrint(
        '[AuthService] Generated mobile link token (expires in 5 min)',
      );

      return (tokenHash: hash, pin: pin);
    } on PostgrestException catch (e) {
      debugPrint('[AuthService] Failed to store token: ${e.message}');
      throw Exception('Failed to generate link token');
    }
  }

  @override
  Future<bool> sendPasswordResetEmail(String email) async {
    try {
      // Supabase will send a password reset email with a link
      // Uses custom URL scheme for deep linking
      await _client.auth.resetPasswordForEmail(
        email,
        redirectTo: kIsWeb ? null : 'ghostcopy://reset-password',
      );
      debugPrint('[AuthService] Password reset email sent to: $email');
      return true;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Send password reset failed: ${e.message}');
      return false;
    }
  }

  @override
  Future<bool> resetPassword(String newPassword) async {
    try {
      // Update the user's password after they've clicked the reset link
      // Supabase automatically validates the reset token from the deep link
      await _client.auth.updateUser(UserAttributes(password: newPassword));
      debugPrint('[AuthService] Password reset successfully');
      return true;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Password reset failed: ${e.message}');
      return false;
    }
  }

  /// Drop everything this device holds for the account being left.
  Future<void> _clearLocalAccountState() async {
    // Reset encryption and repository state before signing out
    _encryption.reset();
    _repository.reset();

    // Same for the clip staged for instant-copy by the FCM background
    // isolate: it holds ONE clip's decrypted plaintext, and CopyActivity only
    // deletes it when the notification is actually tapped. An untapped
    // notification leaves it on disk indefinitely - across a sign-out too.
    await _clearPendingCopy();

    // And the home screen widget's thumbnail cache, which nothing else owns
    // any more. WidgetService created and pruned widget_thumbnails/, and it
    // was deleted along with the widget - but an install upgrading from a
    // build that had one still has the directory, holding decrypted JPEG
    // renderings of clips that are encrypted everywhere else. With no owner
    // left they would outlive every account switch.
    await _clearLegacyWidgetThumbnails();

    debugPrint('[AuthService] Reset encryption and repository state');
  }

  @override
  bool get deletionNeedsAppleConfirmation =>
      _hasNativeAppleSignIn &&
      (currentUser?.identities?.any((i) => i.provider == 'apple') ?? false);

  @override
  Future<AccountDeletionOutcome> deleteAccount() async {
    final user = currentUser;
    if (user == null) throw StateError('No signed-in account to delete');

    // Apple requires revoking an Apple account's tokens when it is deleted,
    // and Supabase keeps none to revoke, so ask Apple once more for a fresh
    // code the server can exchange and revoke. Only where the native sheet
    // exists; elsewhere the server deletes without it and logs the gap.
    String? appleCode;
    if (deletionNeedsAppleConfirmation) {
      try {
        appleCode = await _appleReauthorize();
        if (appleCode == null) return AccountDeletionOutcome.cancelled;
      } on Exception catch (e) {
        // No Apple ID signed in on this device, or Apple itself failed. Only
        // an explicit cancel stops the deletion: revocation is best effort on
        // the server too, and a user who cannot get a code here must still be
        // able to delete the account in the app (App Review 5.1.1(v)).
        debugPrint('[AuthService] No Apple code, deleting without one: $e');
      }
    }

    // Throws on anything but success, before anything local is touched: a
    // failed deletion must leave the user signed in with their data intact.
    await _client.functions.invoke(
      'delete-account',
      body: {'apple_authorization_code': ?appleCode},
    );
    debugPrint('[AuthService] Account deleted on the server');

    // From here the account no longer exists; the rest removes this device's
    // copy of it. Nothing below can undo the deletion, so each step is best
    // effort rather than a reason to report failure.
    try {
      await _encryption.forgetPassphraseLocally(user.id);
    } on Exception catch (e) {
      debugPrint('[AuthService] Could not erase the local passphrase: $e');
    }
    await _clearLocalAccountState();

    // Local scope (the default): the server would reject a global sign-out
    // for a user it has just deleted.
    try {
      await _client.auth.signOut();
    } on AuthException catch (e) {
      debugPrint('[AuthService] Local sign-out after deletion: ${e.message}');
    }
    // The account is already gone. A failed guest sign-in here (network, rate
    // limit) must not turn that into a reported failure - the settings screen
    // would say nothing was deleted. The app signs in as a guest at its next
    // launch anyway.
    try {
      await _client.auth.signInAnonymously();
      debugPrint('[AuthService] On a fresh guest account after deletion');
      await _registerThisDesktop();
    } on Exception catch (e) {
      debugPrint('[AuthService] Guest sign-in after deletion failed: $e');
    }
    return AccountDeletionOutcome.deleted;
  }

  /// The native Apple sheet, asking only for a fresh authorization code.
  // No scopes: this only proves it is still the account holder.
  static Future<String?> _nativeAppleAuthorizationCode() async =>
      (await _requestAppleCredential(scopes: const []))?.authorizationCode;

  @override
  Future<void> signOut() async {
    try {
      final deviceId = _deviceService?.getCurrentDeviceId();
      final userId = currentUserId;
      if (deviceId != null && userId != null) {
        // Do not revoke the session until its globally unique push token has
        // been released. A failed delete leaves sign-out retryable.
        await _client
            .from('devices')
            .delete()
            .eq('id', deviceId)
            .eq('user_id', userId);
      }
      await _clearLocalAccountState();

      await _client.auth.signOut();
      debugPrint('[AuthService] Signed out successfully');

      // Sign back in anonymously
      await _client.auth.signInAnonymously();
      debugPrint('[AuthService] Signed in anonymously after sign out');
      await _registerThisDesktop();
    } on AuthException catch (e) {
      debugPrint('[AuthService] Sign out failed: ${e.message}');
      rethrow;
    }
  }

  /// Delete the instant-copy staging file written by the FCM background
  /// isolate (see main.dart `_writePendingCopy`).
  Future<void> _clearPendingCopy() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/pending_copy.json');
      if (file.existsSync()) {
        await file.delete();
        debugPrint('[AuthService] Cleared staged clip');
      }
    } on Object catch (e) {
      debugPrint('[AuthService] Could not clear staged clip: $e');
    }
  }

  /// Remove the home screen widget's thumbnail cache, left by an older build.
  ///
  /// Best effort and deliberately quiet: it is gone on any install that never
  /// had the widget, and failing to remove it is not a reason to fail a sign
  /// out. Safe to keep running - it is a no-op once the directory is gone, and
  /// nothing recreates it.
  Future<void> _clearLegacyWidgetThumbnails() async {
    try {
      final cacheDir = await getApplicationCacheDirectory();
      final legacy = Directory('${cacheDir.path}/widget_thumbnails');
      if (legacy.existsSync()) {
        await legacy.delete(recursive: true);
        debugPrint('[AuthService] Removed legacy widget thumbnail cache');
      }
    } on Object catch (e) {
      debugPrint('[AuthService] Could not remove widget thumbnails: $e');
    }
  }

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<void> signInWithRefreshToken(String refreshToken) async {
    await _switchAccount(() => _client.auth.setSession(refreshToken));
  }

  Future<T> _switchAccount<T>(Future<T> Function() authenticate) async {
    final previous = _client.auth.currentSession;
    final deviceId = _deviceService?.getCurrentDeviceId();
    final T result;
    try {
      result = await authenticate();
    } on Exception {
      // setSession clears SDK state when a refresh token is rejected. Restore
      // the original session so a bad QR does not also log the user out.
      if (previous != null && _client.auth.currentSession == null) {
        try {
          await _client.auth.recoverSession(jsonEncode(previous.toJson()));
        } on Exception catch (e) {
          debugPrint('[AuthService] Could not restore previous session: $e');
        }
      }
      rethrow;
    }
    await _finishAccountSwitch(previous, deviceId);
    return result;
  }

  /// Tidy up after the session moved from [previous] to the current one:
  /// clean up the account left behind, then register this computer under the
  /// new one.
  Future<void> _finishAccountSwitch(Session? previous, String? deviceId) async {
    final next = _client.auth.currentSession;
    if (previous != null && next != null) {
      await _cleanupPreviousSession(previous, next.user.id, deviceId);
    }
    if (next != null && next.user.id != previous?.user.id) {
      await _registerThisDesktop();
    }
  }

  /// Register this computer under the account it has just moved to.
  ///
  /// Desktop registered only at launch, so after signing in, signing out or
  /// deleting the account it stayed off the new account's device list - the
  /// phone could not see or target it - until the app was restarted. Run
  /// after [_cleanupPreviousSession], which removes the old account's row.
  ///
  /// Desktop only: registering without a push token clears the stored one,
  /// and the mobile screens already re-register with their token after each
  /// of these changes. Best effort, like the registration at launch.
  Future<void> _registerThisDesktop() async {
    final devices = _deviceService;
    if (devices == null ||
        !(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return;
    }
    try {
      await devices.registerCurrentDevice();
    } on Object catch (e) {
      debugPrint('[AuthService] Could not register this device: $e');
    }
  }

  Future<void> _cleanupPreviousSession(
    Session previous,
    String nextUserId,
    String? deviceId,
  ) async {
    if (previous.user.id == nextUserId) return;
    try {
      // Override only this request's JWT. Mutating the shared client headers
      // would race requests made by the newly signed-in account.
      if (previous.user.isAnonymous) {
        await _client
            .rpc<void>(
              'cleanup_user_data',
              params: {'p_user_id': previous.user.id},
            )
            .setHeader('Authorization', 'Bearer ${previous.accessToken}');
      } else if (deviceId != null) {
        await _client
            .from('devices')
            .delete()
            .eq('id', deviceId)
            .eq('user_id', previous.user.id)
            .setHeader('Authorization', 'Bearer ${previous.accessToken}');
      }
    } on Exception catch (e) {
      debugPrint('[AuthService] Previous account cleanup failed: $e');
    }
  }

  @override
  Future<void> cleanupOldAccountData(String oldUserId) async {
    try {
      await _client.rpc<void>(
        'cleanup_user_data',
        params: {'p_user_id': oldUserId},
      );
      debugPrint('[AuthService] ✅ Cleaned up old account data for: $oldUserId');
    } on Object catch (e) {
      debugPrint('[AuthService] ❌ Failed to cleanup old account: $e');
      // Don't throw - cleanup is best-effort, don't block sign-in
    }
  }

  @override
  void dispose() {
    // Nothing is left to wait for the browser.
    cancelBrowserSignIn();

    // Dispose GoogleSignIn instance to prevent memory leaks
    _googleSignIn?.disconnect();
    _googleSignIn = null;

    debugPrint('[AuthService] Disposed');
  }
}
