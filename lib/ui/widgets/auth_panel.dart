import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/notification_service.dart';
import '../account_deletion_text.dart';
import '../guest_clips_guard.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'social_sign_in_buttons.dart';

/// Auth panel for login, signup, and account management
///
/// Extracted from SpotlightScreen to reduce widget complexity.
/// Manages its own state and lifecycle (controllers, focus nodes).
class AuthPanel extends StatefulWidget {
  const AuthPanel({
    required this.authService,
    required this.notificationService,
    required this.clipboardSyncService,
    required this.onClose,
    super.key,
  });

  final IAuthService authService;
  final INotificationService notificationService;
  final IClipboardSyncService clipboardSyncService;
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

  /// A provider sign-in is waiting on the browser, which may never come back
  /// (closed tab, declined consent), so the panel offers a way out.
  bool _awaitingBrowser = false;

  /// True while the account is being deleted, so the button cannot be pressed
  /// twice and shows that something is happening.
  bool _deletingAccount = false;
  String? _authError;

  // Repository instance (shared singleton)
  late final IClipboardRepository _clipboardRepository =
      ClipboardRepository.instance;

  @override
  void dispose() {
    // Nothing would be left to finish a browser sign-in that completes after
    // the panel closes - no post-login work, no realtime move - so do not let
    // one complete.
    if (_awaitingBrowser) widget.authService.cancelBrowserSignIn();
    // Dispose all resources to prevent memory leaks
    try {
      _emailController.dispose();
      _passwordController.dispose();
      // NOTE: ClipboardRepository is a singleton - do NOT dispose it here
    } on Exception catch (e) {
      debugPrint('Error disposing auth panel resources: $e');
    }
    super.dispose();
  }

  /// Shared post-login logic for all auth methods (Google, email, etc.)
  Future<void> _handlePostLogin() async {
    // Auto-restore passphrase from cloud backup if available
    final userId = widget.authService.currentUserId;
    if (userId != null) {
      debugPrint(
        '[AuthPanel] Post-login: restoring passphrase for user $userId',
      );
      final encryptionService = EncryptionService.instance;
      await encryptionService.initialize(userId);

      final restored = await encryptionService.autoRestoreFromCloud();
      if (restored) {
        debugPrint('[AuthPanel] ✅ Passphrase restored from cloud');
        widget.notificationService.showToast(
          message: 'Encryption passphrase restored from cloud',
          type: NotificationType.success,
        );
      } else {
        debugPrint('[AuthPanel] ⚠️ No cloud passphrase backup found');
        final hasPassphrase = await encryptionService.isEnabled();
        if (!hasPassphrase) {
          widget.notificationService.showToast(
            message:
                'No encryption passphrase found. Enable encryption in Settings.',
          );
        }
      }
    }

    // Reinitialize realtime subscription for new/upgraded user
    widget.clipboardSyncService.reinitializeForUser();
    debugPrint('[AuthPanel] ✅ Realtime subscription reinitialized');
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
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text('Switch Account'),
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
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: const Text('Sign Out'),
              ),
            ),
            const SizedBox(height: 4),
            // In-app deletion, as on mobile: the privacy policy points every
            // user at it, and App Review 5.1.1(v) covers the Mac app too.
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _deletingAccount ? null : _handleDeleteAccount,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade400,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                child: _deletingAccount
                    ? Adaptive.progressIndicator(
                        size: 16,
                        color: Colors.red.shade400,
                      )
                    : const Text('Delete Account'),
              ),
            ),
          ],
        ),
      );
    }

    // Anonymous user - show login/signup form.
    //
    // Everything here has to fit 400px without scrolling, which it did not on
    // Windows: the bundled fonts in pubspec.yaml are commented out, so this
    // renders in Segoe UI there and SF on macOS, and Segoe is the taller of
    // the two. The form cleared 400px on a Mac and overflowed on Windows by
    // roughly the difference. The budget is held by a widget test
    // (auth_panel_fits_test.dart) measured at a larger text scale than either
    // platform uses, so the layout has room to be wrong about font metrics and
    // still fit. Adding a row here without checking that test will put the
    // scrollbar back.
    return SingleChildScrollView(
      physics: Adaptive.scrollPhysics,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Login/Signup toggle
          _buildLoginSignupToggle(),
          // No standing explanation of what signing in does to guest clips.
          // confirmGuestClipsBeforeSignIn is the real warning and a better
          // one: it fires at the moment of action, counts the clips actually
          // at risk, says whether they are abandoned or destroyed, and stays
          // out of the way entirely when there is nothing to lose. A
          // paragraph here repeated it to everyone, permanently, and cost the
          // form more height than any other block.
          const SizedBox(height: 12),
          // Email field
          RepaintBoundary(child: _buildEmailField()),
          const SizedBox(height: 10),
          // Password field
          RepaintBoundary(child: _buildPasswordField()),
          // Forgot password link (only show in login mode)
          if (_isLogin) _buildForgotPasswordLink(),
          // Error message
          if (_authError != null) _buildErrorMessage(),
          SizedBox(height: _isLogin ? 6 : 10),
          // Submit button
          RepaintBoundary(child: _buildSubmitButton()),
          const SizedBox(height: 8),
          // The provider buttons sit in the divider rather than under it.
          // Stacked, the rule, its "OR", and the buttons were three blocks and
          // two gaps for what is one idea - "or use one of these" - and the
          // rule reads that way with the buttons inside it. Worth 22px in a
          // form that had none to give.
          _buildAlternativeSignIn(),
          if (_awaitingBrowser) _buildAwaitingBrowser(),
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
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(8),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Sign In',
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
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: !_isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(8),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Create Account',
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
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
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
        const SizedBox(height: 2),
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
            border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _authError!,
                  style: GhostTypography.caption.copyWith(color: Colors.red),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAwaitingBrowser() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              'Finish signing in in your browser.',
              style: GhostTypography.caption.copyWith(
                color: GhostColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: widget.authService.cancelBrowserSignIn,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _authLoading ? null : _handleEmailAuth,
        style: ElevatedButton.styleFrom(
          backgroundColor: GhostColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 10),
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
            : Text(_isLogin ? 'Sign In' : 'Create Account'),
      ),
    );
  }

  /// The third-party options, set into a rule instead of stacked under one.
  ///
  /// Apple: native sheet on macOS, the browser flow on Windows. Either way the
  /// only way onto this computer for someone who signed up on an iPhone with
  /// Apple and Hide My Email - that account has no password.
  Widget _buildAlternativeSignIn() {
    return Row(
      children: [
        const Expanded(child: Divider(color: GhostColors.surface)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: RepaintBoundary(
            child: SocialSignInButtons(
              enabled: !_authLoading,
              onApple: _handleAppleAuth,
              onGoogle: _handleGoogleAuth,
              // Below the widget's own 52 default, but left at what the panel
              // already used rather than shrunk further - these are the only
              // way in for an Apple account with no password, and the row it
              // now sits in gave back more than trimming them would.
              size: 44,
            ),
          ),
        ),
        const Expanded(child: Divider(color: GhostColors.surface)),
      ],
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
        // Orphaned rather than deleted on this path - see the doc comment.
        if (!await confirmGuestClipsBeforeSignIn(
          context,
          authService: widget.authService,
          clipboardRepository: _clipboardRepository,
          deletesClips: false,
        )) {
          if (mounted) setState(() => _authLoading = false);
          return;
        }

        // Sign in existing user - check if switching accounts
        final currentUserId = widget.authService.currentUserId;

        // Sign in with new account
        await widget.authService.signInWithEmail(
          _emailController.text,
          _passwordController.text,
        );

        // Reset local state if switching accounts
        if (currentUserId != null &&
            currentUserId != widget.authService.currentUserId) {
          debugPrint('[AuthPanel] User ID changed, resetting state');
          EncryptionService.instance.reset();
          _clipboardRepository.reset();
          widget.clipboardSyncService.reinitializeForUser();
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

        // Run shared post-login logic (passphrase restore + realtime reinit)
        await _handlePostLogin();

        // Check if user email is confirmed
        final user = widget.authService.currentUser;
        final emailConfirmed = user?.emailConfirmedAt != null;

        if (!emailConfirmed && !_isLogin && mounted) {
          // Email confirmation required - show message
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: GhostColors.surfaceLight,
              title: Row(
                children: [
                  const Icon(
                    Icons.mark_email_unread,
                    color: GhostColors.primary,
                  ),
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

  Future<void> _handleGoogleAuth() => _handleProviderAuth(
    signIn: widget.authService.signInWithGoogle,
    link: widget.authService.linkGoogleIdentity,
  );

  Future<void> _handleAppleAuth() => _handleProviderAuth(
    signIn: widget.authService.signInWithApple,
    link: widget.authService.linkAppleIdentity,
  );

  /// Sign in to an existing account ([signIn]) or, in Sign Up mode, upgrade
  /// the anonymous account in place ([link]) with a third-party provider.
  Future<void> _handleProviderAuth({
    required Future<bool> Function() signIn,
    required Future<bool> Function() link,
  }) async {
    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      bool success;

      if (_isLogin) {
        // Same guard as the email path. Without it, Continue with Google (or
        // Apple) switched accounts directly and AuthService._cleanupPreviousSession
        // then ran cleanup_user_data against the anonymous account, deleting
        // its clipboard rows outright - so the Google button destroyed clips
        // that the email button stops to ask about.
        // deletesClips: this path really does destroy them, so the dialog
        // says so rather than offering the gentler "left behind" wording.
        if (!await confirmGuestClipsBeforeSignIn(
          context,
          authService: widget.authService,
          clipboardRepository: _clipboardRepository,
          deletesClips: true,
        )) {
          if (mounted) setState(() => _authLoading = false);
          return;
        }

        // Login mode: sign in to an existing account - check if switching
        final currentUserId = widget.authService.currentUserId;

        // app_links handles the callback
        success = await _awaitProvider(signIn());

        // Reset local state if switching accounts
        if (success &&
            currentUserId != null &&
            currentUserId != widget.authService.currentUserId) {
          debugPrint('[AuthPanel] User ID changed, resetting state');
          EncryptionService.instance.reset();
          _clipboardRepository.reset();
          widget.clipboardSyncService.reinitializeForUser();
        }
      } else {
        // Sign Up mode: upgrade the anonymous user, keeping user_id and clips
        success = await _awaitProvider(link());
      }

      if (mounted) {
        if (success) {
          // Run shared post-login logic (passphrase restore + realtime reinit)
          await _handlePostLogin();

          // Re-check: the guard above was evaluated BEFORE that await, so the
          // panel may have been disposed while post-login work was running.
          if (!mounted) return;

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

  /// Wait for a provider sign-in, showing the Cancel row while it is out in
  /// the browser. The flow has registered its wait by the time [pending] is
  /// handed over, so checking straight away is enough.
  Future<bool> _awaitProvider(Future<bool> pending) async {
    if (widget.authService.isAwaitingBrowserSignIn && mounted) {
      setState(() => _awaitingBrowser = true);
    }
    try {
      return await pending;
    } finally {
      if (mounted && _awaitingBrowser) {
        setState(() => _awaitingBrowser = false);
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
                    const Icon(
                      Icons.mark_email_read,
                      color: GhostColors.success,
                    ),
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
            _authError =
                'Failed to send reset email. Please check your email address.';
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

  /// Delete the account and everything in it, then carry on as a fresh guest.
  Future<void> _handleDeleteAccount() async {
    final confirmed = await Adaptive.confirm(
      context,
      title: accountDeletionTitle,
      message: accountDeletionWarning(
        appleNext: widget.authService.deletionNeedsAppleConfirmation,
      ),
      confirmText: 'Delete Account',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _deletingAccount = true);
    try {
      final outcome = await widget.authService.deleteAccount();
      if (outcome == AccountDeletionOutcome.cancelled) return;

      // The realtime channel is still on the account that no longer exists.
      widget.clipboardSyncService.reinitializeForUser();
      widget.notificationService.showToast(
        message: 'Your account has been deleted',
        type: NotificationType.success,
      );
      if (mounted) widget.onClose();
    } on Exception catch (e) {
      debugPrint('[AuthPanel] Account deletion failed: $e');
      widget.notificationService.showToast(
        message: accountDeletionFailed,
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
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
