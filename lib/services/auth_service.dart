import 'package:supabase_flutter/supabase_flutter.dart';

/// Abstract interface for authentication service
/// Handles user authentication, session management, and account upgrades
/// How a request to delete the account ended.
enum AccountDeletionOutcome {
  /// The account and everything in it are gone, and this device is back on a
  /// fresh guest account.
  deleted,

  /// The user backed out of the Apple confirmation; nothing was deleted.
  cancelled,
}

abstract class IAuthService {
  /// Initialize the auth service and check current auth state
  Future<void> initialize();

  /// Get the current authenticated user (null if not authenticated)
  User? get currentUser;

  /// Check if the current user is anonymous
  bool get isAnonymous;

  /// Stream of auth state changes for reactive UI updates
  Stream<AuthState> get authStateChanges;

  /// Sign up a new user with email and password
  /// Returns AuthResponse with user data or error
  /// [captchaToken] Required if captcha is enabled in Supabase
  Future<AuthResponse> signUpWithEmail(
    String email,
    String password, {
    String? captchaToken,
  });

  /// Sign in an existing user with email and password
  /// Returns AuthResponse with user data or error
  /// [captchaToken] Required if captcha is enabled in Supabase
  Future<AuthResponse> signInWithEmail(
    String email,
    String password, {
    String? captchaToken,
  });

  /// Sign in with Google OAuth provider
  /// Returns true if successful, false if cancelled or failed
  Future<bool> signInWithGoogle();

  /// Sign in with Apple, replacing the current session the way
  /// [signInWithGoogle] does. Native on iOS and macOS, the browser flow
  /// elsewhere.
  /// Returns true if successful, false if cancelled or failed
  Future<bool> signInWithApple();

  /// Establish a linked-device session using [refreshToken].
  /// Cleans up the previous account only after session establishment succeeds.
  Future<void> signInWithRefreshToken(String refreshToken);

  /// Upgrade anonymous user to email/password account
  /// Uses Supabase's updateUser() to preserve user_id and clipboard data
  /// Throws exception if email already exists
  /// [captchaToken] Required if captcha is enabled in Supabase
  Future<UserResponse> upgradeWithEmail(
    String email,
    String password, {
    String? captchaToken,
  });

  /// Link Google OAuth identity to current anonymous user
  /// Uses Supabase's linkIdentity() to preserve user_id
  /// Returns true if successful, false if cancelled or failed
  Future<bool> linkGoogleIdentity();

  /// Link an Apple identity to the current anonymous user, preserving user_id
  /// and clipboard data. Native on iOS and macOS, the browser flow elsewhere.
  /// Returns true if successful, false if cancelled or failed
  Future<bool> linkAppleIdentity();

  /// Permanently delete the signed-in account and everything in it - clips,
  /// stored files, devices - then leave this device on a fresh guest account.
  ///
  /// Apple accounts are asked to confirm with Apple first, where the native
  /// sheet exists, so their Apple tokens can be revoked as Apple requires.
  /// Throws if the server could not delete the account; nothing local is
  /// cleared in that case.
  Future<AccountDeletionOutcome> deleteAccount();

  /// Generate a time-limited token for mobile device linking
  /// Token expires after 5 minutes
  /// Returns token string in format: ghostcopy://link?token={jwt_token}
  /// Mint a single-use device-linking token plus the 6-digit PIN that unlocks
  /// it.
  ///
  /// The token goes in the QR code; the PIN is displayed on screen and must be
  /// typed on the receiving device. Only the PIN's SHA-256 is stored, and the
  /// server matches it as part of consuming the token, so a photographed QR on
  /// its own is useless. The passphrase is deliberately NOT included - it is
  /// entered by hand on each device.
  Future<({String tokenHash, String pin})> generateMobileLinkToken();

  /// Send password reset email to user
  /// Returns true if email sent successfully, false otherwise
  /// User will receive an email with a link to reset their password
  Future<bool> sendPasswordResetEmail(String email);

  /// Reset password using the reset token from email
  /// Called after user clicks the link in the password reset email
  /// Returns true if password updated successfully
  Future<bool> resetPassword(String newPassword);

  /// Sign out the current user
  /// Clears session and returns to anonymous state
  Future<void> signOut();

  /// Get the current user's ID
  /// Returns null if no user is authenticated
  String? get currentUserId;

  /// Clean up all data for a user when switching to a different account
  /// Calls database function to delete clipboard, devices, passphrases, and tokens
  /// Best-effort operation - errors are logged but don't throw
  Future<void> cleanupOldAccountData(String oldUserId);

  /// Dispose of any resources (streams, controllers, etc.)
  void dispose();
}
