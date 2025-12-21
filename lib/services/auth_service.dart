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
  Future<AuthResponse> signUpWithEmail(String email, String password);

  /// Sign in an existing user with email and password
  /// Returns AuthResponse with user data or error
  Future<AuthResponse> signInWithEmail(String email, String password);

  /// Sign in with Google OAuth provider
  /// Returns true if successful, false if cancelled or failed
  Future<bool> signInWithGoogle();

  /// Upgrade anonymous user to email/password account
  /// Uses Supabase's updateUser() to preserve user_id and clipboard data
  /// Throws exception if email already exists
  Future<UserResponse> upgradeWithEmail(String email, String password);

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

  /// Sign out the current user
  /// Clears session and returns to anonymous state
  Future<void> signOut();

  /// Dispose of any resources (streams, controllers, etc.)
  void dispose();
}
