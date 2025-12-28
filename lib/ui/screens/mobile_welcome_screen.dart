import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../main.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/impl/passphrase_sync_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Mobile welcome/auth screen with QR code scanning and email/Google auth
///
/// Design: Dark theme with glassmorphism, matching desktop app
/// Performance: Proper disposal, RepaintBoundary, const where possible
class MobileWelcomeScreen extends StatefulWidget {
  const MobileWelcomeScreen({
    required this.authService,
    required this.deviceService,
    required this.onAuthComplete,
    this.fcmToken,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final VoidCallback onAuthComplete;
  final String? fcmToken;

  @override
  State<MobileWelcomeScreen> createState() => _MobileWelcomeScreenState();
}

class _MobileWelcomeScreenState extends State<MobileWelcomeScreen>
    with SingleTickerProviderStateMixin {
  // Tab controller for switching between QR scan and email/Google auth
  late final TabController _tabController;

  // QR code scanner controller
  MobileScannerController? _scannerController;

  // Auth form state
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLogin = true; // true = login, false = signup
  bool _authLoading = false;
  String? _authError;

  // QR scanning state
  bool _qrScanning = false;
  String? _qrError;

  // Repository instance (cached to prevent multiple allocations)
  late final IClipboardRepository _clipboardRepository =
      ClipboardRepository();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    // Dispose all resources to prevent memory leaks
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _scannerController?.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _clipboardRepository.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == 0) {
      // QR tab - initialize scanner if not already initialized
      if (_scannerController == null) {
        setState(() {
          _scannerController = MobileScannerController(
            detectionSpeed: DetectionSpeed.noDuplicates,
          );
        });
      }
    } else {
      // Auth tab - dispose scanner to save resources
      _scannerController?.dispose();
      setState(() {
        _scannerController = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GhostColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            _buildHeader(),
            // Tab bar
            _buildTabBar(),
            // Tab views
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildQRScanTab(),
                  _buildAuthTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // App logo/icon placeholder
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: GhostColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: GhostColors.glassBorder,
              ),
            ),
            child: const Icon(
              Icons.content_copy_rounded,
              size: 40,
              color: GhostColors.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'GhostCopy',
            style: GhostTypography.headline.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: GhostColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sync clipboard across devices',
            style: GhostTypography.body.copyWith(
              color: GhostColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: GhostColors.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: GhostColors.textSecondary,
        labelStyle: GhostTypography.body.copyWith(
          fontWeight: FontWeight.w600,
        ),
        tabs: const [
          Tab(
            icon: Icon(Icons.qr_code_scanner),
            text: 'Scan QR',
          ),
          Tab(
            icon: Icon(Icons.login),
            text: 'Sign In',
          ),
        ],
      ),
    );
  }

  Widget _buildQRScanTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Instructions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: GhostColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: GhostColors.glassBorder,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  color: GhostColors.primary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Scan QR code from desktop app to link devices anonymously',
                    style: GhostTypography.caption.copyWith(
                      color: GhostColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // QR Scanner
          _buildQRScanner(),
          if (_qrError != null) ...[
            const SizedBox(height: 16),
            _buildQRError(),
          ],
        ],
      ),
    );
  }

  Widget _buildQRScanner() {
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: GhostColors.glassBorder,
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: () {
          final controller = _scannerController;
          return controller != null
              ? Stack(
                  children: [
                    MobileScanner(
                      controller: controller,
                      onDetect: _onQRCodeDetected,
                    ),
                  if (_qrScanning)
                    Container(
                      color: Colors.black54,
                      child: const Center(
                        child: CircularProgressIndicator(
                          color: GhostColors.primary,
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Text(
                    'Switch to this tab to activate scanner',
                    style: GhostTypography.caption.copyWith(
                      color: GhostColors.textMuted,
                    ),
                  ),
                );
        }(),
      ),
    );
  }

  Widget _buildQRError() {
    return Container(
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
              _qrError!,
              style: GhostTypography.caption.copyWith(
                color: Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
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
          if (_authError != null) _buildAuthError(),
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
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _isLogin = true),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: _isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
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
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _isLogin = false),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: !_isLogin ? GhostColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Sign Up',
                  style: GhostTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    color:
                        !_isLogin ? Colors.white : GhostColors.textSecondary,
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
      decoration: InputDecoration(
        labelText: 'Email',
        filled: true,
        fillColor: GhostColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: GhostColors.primary, width: 2),
        ),
      ),
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      style: GhostTypography.body.copyWith(color: GhostColors.textPrimary),
    );
  }

  Widget _buildPasswordField() {
    return TextField(
      controller: _passwordController,
      decoration: InputDecoration(
        labelText: 'Password',
        filled: true,
        fillColor: GhostColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: GhostColors.primary, width: 2),
        ),
      ),
      obscureText: true,
      autocorrect: false,
      style: GhostTypography.body.copyWith(color: GhostColors.textPrimary),
    );
  }

  Widget _buildForgotPasswordLink() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: _authLoading ? null : _handleForgotPassword,
        child: Text(
          'Forgot Password?',
          style: GhostTypography.caption.copyWith(
            color: GhostColors.primary,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }

  Widget _buildAuthError() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
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
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: _authLoading ? null : _handleEmailAuth,
        style: ElevatedButton.styleFrom(
          backgroundColor: GhostColors.primary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
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
            : Text(
                _isLogin ? 'Login' : 'Sign Up',
                style: GhostTypography.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
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
      label: Text(
        'Continue with Google',
        style: GhostTypography.body.copyWith(fontWeight: FontWeight.w600),
      ),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        side: const BorderSide(color: GhostColors.surface),
        foregroundColor: GhostColors.textPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  // QR Code handlers
  Future<void> _onQRCodeDetected(BarcodeCapture capture) async {
    if (_qrScanning) return; // Prevent multiple scans

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final code = barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    setState(() {
      _qrScanning = true;
      _qrError = null;
    });

    try {
      debugPrint('[QR] Scanned code length: ${code.length}');

      // Parse QR code JSON data
      // Format: {"link_token": "...", "passphrase_encrypted": "...", "version": 1}
      late Map<String, dynamic> qrData;
      try {
        qrData = jsonDecode(code) as Map<String, dynamic>;
      } on FormatException catch (_) {
        throw Exception('Invalid QR code format. Please scan a GhostCopy QR code.');
      }

      // Validate QR data structure
      if (!qrData.containsKey('link_token') || !qrData.containsKey('version')) {
        throw Exception('Invalid QR code: missing required fields.');
      }

      final linkToken = qrData['link_token'] as String?;
      final encryptedPassphrase = qrData['passphrase_encrypted'] as String?;

      if (linkToken == null || linkToken.isEmpty) {
        throw Exception('Invalid QR code: missing token.');
      }

      debugPrint('[QR] Exchanging link token...');

      // Call edge function to exchange token for session
      final response = await supabase.functions.invoke(
        'exchange-link-token',
        body: {'token': linkToken},
      );

      if (response.status != 200 || response.data == null) {
        final errorData = response.data as Map<String, dynamic>?;
        final errorMsg = errorData?['error'] as String? ?? 'Failed to authenticate';
        throw Exception(errorMsg);
      }

      final data = response.data as Map<String, dynamic>;
      final refreshToken = data['refresh_token'] as String;

      debugPrint('[QR] ✅ Got session tokens, setting session...');

      // Set session in Supabase client using refresh token
      await supabase.auth.setSession(refreshToken);

      debugPrint('[QR] ✅ Session set');

      // Import passphrase if included in QR code
      if (encryptedPassphrase != null) {
        debugPrint('[QR] Importing encrypted passphrase...');
        try {
          // Initialize with cloud backup support for authenticated users
          final encryptionService = EncryptionService(
            passphraseSyncService: PassphraseSyncService(),
          );
          final userId = supabase.auth.currentUser?.id;
          if (userId != null) {
            await encryptionService.initialize(userId);
            final imported = await encryptionService.importPassphraseFromQr(encryptedPassphrase);
            if (imported) {
              debugPrint('[QR] ✅ Passphrase imported successfully');
            } else {
              debugPrint('[QR] ⚠️ Failed to import passphrase');
            }
            encryptionService.dispose();
          }
        } on Exception catch (e) {
          debugPrint('[QR] ⚠️ Passphrase import error: $e');
          // Continue anyway - encryption is optional
        }
      }

      // Register device and update FCM token
      if (mounted) {
        await widget.deviceService.registerCurrentDevice();

        if (widget.fcmToken != null) {
          await widget.deviceService.updateFcmToken(widget.fcmToken!);
          debugPrint('[QR] ✅ Device registered with FCM token');
        }

        debugPrint('[QR] ✅ QR authentication complete');
        widget.onAuthComplete();
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _qrError = e.toString().replaceAll('Exception: ', '');
          _qrScanning = false;
        });
      }
    }
  }

  // Auth handlers
  Future<void> _handleEmailAuth() async {
    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      // Mobile doesn't use hCaptcha - simplified auth flow
      if (_isLogin) {
        // Sign in existing user - check if switching accounts
        final currentUserId = widget.authService.currentUserId;
        final wasAnonymous = widget.authService.isAnonymous;

        // Sign in with new account (no captcha on mobile)
        await widget.authService.signInWithEmail(
          _emailController.text,
          _passwordController.text,
        );

        // Clean up old account data ONLY if it was anonymous
        if (wasAnonymous &&
            currentUserId != null &&
            currentUserId != widget.authService.currentUserId) {
          await widget.authService.cleanupOldAccountData(currentUserId);
        }
      } else {
        // Upgrade anonymous to permanent account
        await widget.authService.upgradeWithEmail(
          _emailController.text,
          _passwordController.text,
        );
      }

      // Success - register device with FCM token before navigating
      if (mounted) {
        // Register device
        await widget.deviceService.registerCurrentDevice();

        // Update FCM token if available
        if (widget.fcmToken != null) {
          await widget.deviceService.updateFcmToken(widget.fcmToken!);
          debugPrint('[Mobile] ✅ Device registered with FCM token after email auth');
        }

        widget.onAuthComplete();
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
        // Login mode: Sign in with existing Google account
        final currentUserId = widget.authService.currentUserId;
        final wasAnonymous = widget.authService.isAnonymous;

        // Sign in with Google
        success = await widget.authService.signInWithGoogle();

        // Clean up old account data ONLY if it was anonymous
        if (success &&
            wasAnonymous &&
            currentUserId != null &&
            currentUserId != widget.authService.currentUserId) {
          await widget.authService.cleanupOldAccountData(currentUserId);
        }
      } else {
        // Sign Up mode: Upgrade anonymous user to Google account
        success = await widget.authService.linkGoogleIdentity();
      }

      if (mounted) {
        if (success) {
          // Success - register device with FCM token before navigating
          await widget.deviceService.registerCurrentDevice();

          // Update FCM token if available
          if (widget.fcmToken != null) {
            await widget.deviceService.updateFcmToken(widget.fcmToken!);
            debugPrint('[Mobile] ✅ Device registered with FCM token after Google auth');
          }

          widget.onAuthComplete();
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
          if (mounted) {
            unawaited(showDialog<void>(
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
                  'Check your email for a password reset link.',
                  style: GhostTypography.body.copyWith(
                    color: GhostColors.textSecondary,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(
                      'OK',
                      style: TextStyle(color: GhostColors.primary),
                    ),
                  ),
                ],
              ),
            ));
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
}
