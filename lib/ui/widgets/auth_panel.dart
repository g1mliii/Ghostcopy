import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/notification_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Auth panel for login, signup, and account management
///
/// Extracted from SpotlightScreen to reduce widget complexity.
/// Manages its own state and lifecycle (controllers, focus nodes).
class AuthPanel extends StatefulWidget {
  const AuthPanel({
    required this.authService,
    required this.notificationService,
    required this.onClose,
    super.key,
  });

  final IAuthService authService;
  final INotificationService notificationService;
  final VoidCallback onClose;

  @override
  State<AuthPanel> createState() => _AuthPanelState();
}

class _AuthPanelState extends State<AuthPanel> {
  // Text controllers
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // Auth state
  bool _isLogin = true; // true = login, false = signup
  bool _authLoading = false;
  String? _authError;

  // Repository instance (cached to prevent multiple allocations)
  late final IClipboardRepository _clipboardRepository = ClipboardRepository();

  @override
  void dispose() {
    // Dispose all resources to prevent memory leaks
    try {
      _emailController.dispose();
      _passwordController.dispose();
      _clipboardRepository.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing auth panel resources: $e');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.authService.isAnonymous) {
      // User is already logged in - show account management
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Signed in as',
              style: GhostTypography.caption.copyWith(
                color: GhostColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.authService.currentUser?.email ?? '',
              style: GhostTypography.body.copyWith(
                fontWeight: FontWeight.w600,
                color: GhostColors.textPrimary,
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _handleSignInDifferent,
                style: ElevatedButton.styleFrom(
                  backgroundColor: GhostColors.primaryHover,
                  foregroundColor: GhostColors.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Sign In with Different Account'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _handleSignOut,
                style: ElevatedButton.styleFrom(
                  backgroundColor: GhostColors.surface,
                  foregroundColor: GhostColors.textPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Sign Out'),
              ),
            ),
          ],
        ),
      );
    }

    // Anonymous user - show login/signup form
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Login/Signup toggle
          _buildLoginSignupToggle(),
          const SizedBox(height: 24),
          // Email field
          RepaintBoundary(child: _buildEmailField()),
          const SizedBox(height: 16),
          // Password field
          RepaintBoundary(child: _buildPasswordField()),
          // Forgot password link (only show in login mode)
          if (_isLogin) _buildForgotPasswordLink(),
          // Error message
          if (_authError != null) _buildErrorMessage(),
          const SizedBox(height: 16),
          // Submit button
          RepaintBoundary(child: _buildSubmitButton()),
          const SizedBox(height: 16),
          // Divider
          _buildDivider(),
          const SizedBox(height: 16),
          // Google sign in
          RepaintBoundary(child: _buildGoogleSignInButton()),
        ],
      ),
    );
  }

  Widget _buildLoginSignupToggle() {
    return Container(
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _isLogin = true),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(8),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: _isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Login',
                  style: GhostTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: _isLogin ? Colors.white : GhostColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _isLogin = false),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(8),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !_isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Sign Up',
                  style: GhostTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color: !_isLogin ? Colors.white : GhostColors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailField() {
    return TextField(
      controller: _emailController,
      decoration: const InputDecoration(
        labelText: 'Email',
        filled: true,
        fillColor: GhostColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: GhostColors.primary, width: 2),
        ),
      ),
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      decoration: const InputDecoration(
        labelText: 'Password',
        filled: true,
        fillColor: GhostColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          borderSide: BorderSide(color: GhostColors.primary, width: 2),
        ),
      ),
      obscureText: true,
      autocorrect: false,
    );
  }

  Widget _buildForgotPasswordLink() {
    return Column(
      children: [
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _authLoading ? null : _handleForgotPassword,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Forgot Password?',
              style: GhostTypography.caption.copyWith(
                color: GhostColors.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Column(
      children: [
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.red.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _authError!,
                  style: GhostTypography.caption.copyWith(
                    color: Colors.red,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _authLoading ? null : _handleEmailAuth,
        style: ElevatedButton.styleFrom(
          backgroundColor: GhostColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: _authLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(_isLogin ? 'Login' : 'Sign Up'),
      ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        const Expanded(child: Divider(color: GhostColors.surface)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
        ),
        const Expanded(child: Divider(color: GhostColors.surface)),
      ],
    );
  }

  Widget _buildGoogleSignInButton() {
    return OutlinedButton.icon(
      onPressed: _authLoading ? null : _handleGoogleAuth,
      icon: const Icon(Icons.login, size: 18),
      label: const Text('Continue with Google'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        side: const BorderSide(color: GhostColors.surface),
        foregroundColor: GhostColors.textPrimary,
      ),
    );
  }

  // Auth handlers
  Future<void> _handleEmailAuth() async {
    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      // Note: hCaptcha disabled for mobile compatibility
      // Can be re-enabled on desktop if needed
      if (_isLogin) {
        // Sign in existing user - check if switching accounts
        final currentUserId = widget.authService.currentUserId;
        final wasAnonymous = widget.authService.isAnonymous;

        // Warn user if they're about to lose local data when switching accounts
        if (currentUserId != null) {
          final clipboardCount = await _clipboardRepository.getClipboardCountForCurrentUser();

          if (clipboardCount > 0) {
            // Show warning notification for both anonymous and permanent accounts
            widget.notificationService.showToast(
              message: 'Switching accounts will erase $clipboardCount local clipboard item${clipboardCount != 1 ? 's' : ''}',
              type: NotificationType.warning,
              duration: const Duration(seconds: 4),
            );
          }
        }

        // Sign in with new account
        await widget.authService.signInWithEmail(
          _emailController.text,
          _passwordController.text,
        );

        // Clean up old account data ONLY if it was anonymous
        // Permanent accounts should keep their data in Supabase
        if (wasAnonymous && currentUserId != null && currentUserId != widget.authService.currentUserId) {
          await widget.authService.cleanupOldAccountData(currentUserId);
        }
      } else {
        // Upgrade anonymous to permanent account
        await widget.authService.upgradeWithEmail(
          _emailController.text,
          _passwordController.text,
        );
      }

      // Success - check if email confirmation is required
      if (mounted) {
        setState(() => _authLoading = false);

        // Check if user email is confirmed
        final user = widget.authService.currentUser;
        final emailConfirmed = user?.emailConfirmedAt != null;

        if (!emailConfirmed && !_isLogin) {
          // Email confirmation required - show message
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: GhostColors.surfaceLight,
              title: Row(
                children: [
                  const Icon(Icons.mark_email_unread, color: GhostColors.primary),
                  const SizedBox(width: 12),
                  Text(
                    'Verify Your Email',
                    style: GhostTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: GhostColors.textPrimary,
                    ),
                  ),
                ],
              ),
              content: Text(
                "We've sent a confirmation email to ${_emailController.text}. "
                'Please click the link in the email to verify your account.',
                style: GhostTypography.body.copyWith(
                  color: GhostColors.textSecondary,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'OK',
                    style: TextStyle(color: GhostColors.primary),
                  ),
                ),
              ],
            ),
          );
        }

        // Close auth panel and clear fields
        widget.onClose();
        _emailController.clear();
        _passwordController.clear();
      }
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _authError = e.message;
          _authLoading = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _authError = e.toString().replaceAll('Exception: ', '');
          _authLoading = false;
        });
      }
    }
  }

  Future<void> _handleGoogleAuth() async {
    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      final bool success;

      if (_isLogin) {
        // Login mode: Sign in with existing Google account - check if switching accounts
        final currentUserId = widget.authService.currentUserId;
        final wasAnonymous = widget.authService.isAnonymous;

        // Warn user if they're about to lose local data when switching accounts
        if (currentUserId != null) {
          final clipboardCount = await _clipboardRepository.getClipboardCountForCurrentUser();

          if (clipboardCount > 0) {
            // Show warning notification for both anonymous and permanent accounts
            widget.notificationService.showToast(
              message: 'Switching accounts will erase $clipboardCount local clipboard item${clipboardCount != 1 ? 's' : ''}',
              type: NotificationType.warning,
              duration: const Duration(seconds: 4),
            );
          }
        }

        // Sign in with Google
        success = await widget.authService.signInWithGoogle();

        // Clean up old account data ONLY if it was anonymous
        // Permanent accounts should keep their data in Supabase
        if (success && wasAnonymous && currentUserId != null && currentUserId != widget.authService.currentUserId) {
          await widget.authService.cleanupOldAccountData(currentUserId);
        }
      } else {
        // Sign Up mode: Upgrade anonymous user to Google account
        success = await widget.authService.linkGoogleIdentity();
      }

      if (mounted) {
        if (success) {
          // Success - close auth panel
          widget.onClose();
          setState(() => _authLoading = false);
        } else {
          // User cancelled or failed
          setState(() => _authLoading = false);
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _authError = e.toString().replaceAll('Exception: ', '');
          _authLoading = false;
        });
      }
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _authError = 'Please enter your email address';
      });
      return;
    }

    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      final success = await widget.authService.sendPasswordResetEmail(email);

      if (mounted) {
        setState(() => _authLoading = false);

        if (success) {
          // Show success message
          setState(() {
            _authError = null;
          });

          // Show success dialog
          if (mounted) {
            await showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: GhostColors.surfaceLight,
                title: Row(
                  children: [
                    const Icon(Icons.mark_email_read, color: GhostColors.success),
                    const SizedBox(width: 12),
                    Text(
                      'Email Sent',
                      style: GhostTypography.body.copyWith(
                        fontWeight: FontWeight.w600,
                        color: GhostColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                content: Text(
                  'Check your email for a password reset link. The link will expire in 1 hour.',
                  style: GhostTypography.body.copyWith(
                    color: GhostColors.textSecondary,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'OK',
                      style: TextStyle(color: GhostColors.primary),
                    ),
                  ),
                ],
              ),
            );
          }
        } else {
          setState(() {
            _authError = 'Failed to send reset email. Please check your email address.';
          });
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _authError = e.toString().replaceAll('Exception: ', '');
          _authLoading = false;
        });
      }
    }
  }

  Future<void> _handleSignInDifferent() async {
    // Switch to login mode and show login form
    setState(() {
      _isLogin = true;
      _authError = null;
      _emailController.clear();
      _passwordController.clear();
    });
  }

  Future<void> _handleSignOut() async {
    try {
      await widget.authService.signOut();

      if (mounted) {
        widget.onClose();
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _authError = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
  }
}
