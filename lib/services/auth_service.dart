import 'package:supabase_flutter/supabase_flutter.dart';

/// Abstract interface for authentication service
/// Handles user authentication, session management, and account upgrades
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

  /// Generate a time-limited token for mobile device linking
  /// Token expires after 5 minutes
  /// Returns token string in format: ghostcopy://link?token={jwt_token}
  Future<String> generateMobileLinkToken();

  /// Sign in using a mobile link token
  /// Returns AuthResponse with user data or error if token is expired/invalid
  Future<AuthResponse> signInWithToken(String token);

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
