import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth_service.dart';

/// Concrete implementation of IAuthService using Supabase Auth
class AuthService implements IAuthService {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    // Sign in anonymously if no user exists
    final currentUser = _client.auth.currentUser;
    if (currentUser == null) {
      try {
        await _client.auth.signInAnonymously();
        debugPrint('[AuthService] Signed in anonymously');
      } on AuthException catch (e) {
        debugPrint('[AuthService] Failed to sign in anonymously: ${e.message}');
        rethrow;
      }
    } else {
      debugPrint('[AuthService] Already signed in as: ${currentUser.id}');
      if (currentUser.isAnonymous) {
        debugPrint('[AuthService] User is anonymous');
      } else {
        debugPrint('[AuthService] User email: ${currentUser.email}');
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
      debugPrint('[AuthService] Sign up successful for: $email');
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
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
        captchaToken: captchaToken,
      );
      debugPrint('[AuthService] Sign in successful for: $email');
      return response;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Sign in failed: ${e.message}');
      rethrow;
    }
  }

  @override
  Future<bool> signInWithGoogle() async {
    try {
      // Use web-based OAuth flow for all platforms (desktop and mobile)
      // This opens a browser window/webview for authentication
      // For mobile, the user is brought back via deep linking
      final response = await _client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : 'ghostcopy://auth-callback',
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
      debugPrint('[AuthService] Google sign in initiated');
      return response;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Google sign in failed: ${e.message}');
      return false;
    }
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
        UserAttributes(
          email: email,
          password: password,
        ),
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
      // Use linkIdentity to upgrade anonymous user to Google OAuth
      // This preserves the user_id and all clipboard data
      // Opens browser/webview for Google authentication
      final response = await _client.auth.linkIdentity(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : 'ghostcopy://auth-callback',
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
      debugPrint('[AuthService] Google identity linked (user_id preserved)');
      return response;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Link Google identity failed: ${e.message}');
      return false;
    }
  }

  @override
  Future<String> generateMobileLinkToken() async {
    final userId = currentUser?.id;
    if (userId == null) {
      throw Exception('User must be authenticated to generate link token');
    }

    // Generate a secure random token
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final random = DateTime.now().microsecondsSinceEpoch.toString();
    final tokenData = '$userId:$timestamp:$random';
    final bytes = utf8.encode(tokenData);
    final hash = sha256.convert(bytes).toString();

    // Token expires in 5 minutes
    final expiresAt =
        DateTime.now().add(const Duration(minutes: 5)).toIso8601String();

    // Store token in database
    try {
      await _client.from('mobile_link_tokens').insert({
        'user_id': userId,
        'token': hash,
        'expires_at': expiresAt,
      });

      debugPrint('[AuthService] Generated mobile link token (expires in 5 min)');

      // Return token in deep link format
      return 'ghostcopy://link?token=$hash';
    } on PostgrestException catch (e) {
      debugPrint('[AuthService] Failed to store token: ${e.message}');
      throw Exception('Failed to generate link token');
    }
  }

  @override
  Future<AuthResponse> signInWithToken(String token) async {
    try {
      // Verify token exists and is not expired
      final result = await _client
          .from('mobile_link_tokens')
          .select('user_id, expires_at')
          .eq('token', token)
          .single();

      final expiresAt = DateTime.parse(result['expires_at'] as String);
      if (DateTime.now().isAfter(expiresAt)) {
        throw Exception('Token has expired');
      }

      // Sign in as this user
      // Note: This requires a custom Supabase Edge Function to exchange
      // the token for a session. For now, we'll throw a not implemented error.
      // The user_id from the token would be: result['user_id']
      throw UnimplementedError(
        'Token-based sign in requires custom Edge Function implementation',
      );
    } on PostgrestException catch (e) {
      debugPrint('[AuthService] Token verification failed: ${e.message}');
      throw Exception('Invalid or expired token');
    }
  }

  @override
  Future<bool> sendPasswordResetEmail(String email) async {
    try {
      // Supabase will send a password reset email with a link
      // The link redirects to: ghostcopy://reset-password?token=...
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
      await _client.auth.updateUser(
        UserAttributes(password: newPassword),
      );
      debugPrint('[AuthService] Password reset successfully');
      return true;
    } on AuthException catch (e) {
      debugPrint('[AuthService] Password reset failed: ${e.message}');
      return false;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
      debugPrint('[AuthService] Signed out successfully');

      // Sign back in anonymously
      await _client.auth.signInAnonymously();
      debugPrint('[AuthService] Signed in anonymously after sign out');
    } on AuthException catch (e) {
      debugPrint('[AuthService] Sign out failed: ${e.message}');
      rethrow;
    }
  }

  @override
  void dispose() {
    // Cancel auth state subscription if it exists
    _authStateSubscription?.cancel();
    _authStateSubscription = null;
    debugPrint('[AuthService] Disposed');
  }
}
