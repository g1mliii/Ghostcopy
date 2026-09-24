import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../locator.dart';
import '../../main.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../guest_clips_guard.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../widgets/social_sign_in_buttons.dart';

/// Mobile welcome/auth screen with QR code scanning and email/Google auth
///
/// Design: Dark theme with glassmorphism, matching desktop app
/// Performance: Proper disposal, RepaintBoundary, const where possible
class MobileWelcomeScreen extends StatefulWidget {
  const MobileWelcomeScreen({
    required this.onAuthComplete,
    this.fcmTokenFuture,
    super.key,
  });

  final VoidCallback onAuthComplete;
  final Future<String?>? fcmTokenFuture;

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
  static const int _qrTabIndex = 0;
  bool _qrScanning = false;
  String? _qrError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);

    // The controller starts on the QR tab, and a TabController listener only
    // fires on a *change* - so nothing created the scanner on first launch and
    // the tab sat on its "Switch to this tab to activate scanner" placeholder
    // until the user switched away and back. Create it for the starting tab.
    //
    // Unconditional: the controller is built with the default initialIndex and
    // _qrTabIndex is 0, so the guard that used to be here could not be false.
    // Assigned directly rather than through setState: build has not run yet.
    _scannerController = _newScannerController();
  }

  /// The scanner's configuration, in one place.
  ///
  /// Built here and again on the first switch to the QR tab; written out twice
  /// it was two places to change a detection setting.
  MobileScannerController _newScannerController() =>
      MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);

  @override
  void dispose() {
    // Dispose all resources to prevent memory leaks
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    _scannerController?.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    // NOTE: ClipboardRepository is a singleton - do NOT dispose it here
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.index == _qrTabIndex) {
      // QR tab - initialize scanner if not already initialized (Fix #18)
      // Create controller OUTSIDE setState, then trigger rebuild
      if (_scannerController == null) {
        final controller = _newScannerController();
        setState(() {
          _scannerController = controller;
        });
      }
    } else {
      // Auth tab - dispose scanner to save resources
      final controllerToDispose = _scannerController;
      setState(() {
        _scannerController = null;
      });
      controllerToDispose?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GhostColors.background,
      body: SafeArea(
        // Capped and centred, like the main and settings screens. This screen
        // is a stack of full-width controls, so on a tablet the Scan QR / Sign
        // In pair, the Login / Sign Up tabs and the email and password fields
        // all stretched the full 1300dp - a sign-in form running the width of an
        // iPad, with each label stranded far from its field.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: GhostSpacing.maxContentWidth,
            ),
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
                    children: [_buildQRScanTab(), _buildAuthTab()],
                  ),
                ),
              ],
            ),
          ),
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
            decoration: ShapeDecoration(
              color: GhostColors.surface,
              shape: Adaptive.surfaceShape(
                radius: 20,
                side: BorderSide(color: GhostColors.glassBorder),
              ),
            ),
            // The real mark, not a generic Material copy glyph. White variant:
            // this sits on GhostColors.surface, which is near-black.
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Image.asset('assets/icons/logo_white.png'),
            ),
          ),
          const SizedBox(height: 16),
          // The wordmark still scales with the user's text size, but it shrinks
          // to fit rather than wrapping: at the larger accessibility sizes it
          // broke mid-word into "GhostCo / py", which reads as a layout fault
          // rather than a brand. A name is one object, not a sentence.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              'GhostCopy',
              maxLines: 1,
              style: GhostTypography.headline.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: GhostColors.textPrimary,
              ),
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

  /// Height for a tab carrying an icon above a label.
  ///
  /// Flutter's default is a flat 72, which does not move when the user turns
  /// text size up. The icon is a fixed 24 and the padding around it is fixed
  /// too; only the label grows, so only the label's share is scaled.
  static double _tabHeight(BuildContext context) {
    const iconAndPadding = 72.0 - 20.0;
    return iconAndPadding + MediaQuery.textScalerOf(context).scale(20);
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
        // Tab fixes its own height - 72 when it carries both an icon and a
        // label - and nothing in it grows with text scaling, so at the larger
        // accessibility sizes the label ran straight out of the bottom:
        // "BOTTOM OVERFLOWED BY 16 PIXELS" across both tabs, with "Scan QR"
        // and "Sign In" clipped mid-word. Scaling the height with the text
        // keeps the label inside it.
        //
        // This is the first screen a new user sees, so it is also the worst
        // place in the app to have it.
        labelPadding: EdgeInsets.zero,
        indicator: BoxDecoration(
          color: GhostColors.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelColor: Colors.white,
        unselectedLabelColor: GhostColors.textSecondary,
        labelStyle: GhostTypography.body.copyWith(fontWeight: FontWeight.w600),
        tabs: [
          Tab(
            icon: const Icon(Icons.qr_code_scanner),
            text: 'Scan QR',
            height: _tabHeight(context),
          ),
          Tab(
            icon: const Icon(Icons.login),
            text: 'Sign In',
            height: _tabHeight(context),
          ),
        ],
      ),
    );
  }

  Widget _buildQRScanTab() {
    return SingleChildScrollView(
      physics: Adaptive.scrollPhysics,
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Instructions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: GhostColors.surface,
              shape: Adaptive.surfaceShape(
                radius: 12,
                side: BorderSide(color: GhostColors.glassBorder),
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
          // QR Scanner - centred, since it no longer fills the column width.
          Center(child: _buildQRScanner()),
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
      // Square, and no wider than it is tall. A camera viewfinder stretched to
      // the full width of a tablet shows a letterboxed preview of a square
      // subject, and the framing guides stop matching what the camera sees.
      // 320 is roughly the width this had on a phone, so nothing changes there.
      height: 320,
      width: 320,
      decoration: ShapeDecoration(
        color: GhostColors.surface,
        shape: Adaptive.surfaceShape(
          radius: 12,
          side: BorderSide(color: GhostColors.glassBorder, width: 2),
        ),
      ),
      clipBehavior: Clip.antiAlias,
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
                      child: Center(
                        child: Adaptive.progressIndicator(
                          size: 32,
                          strokeWidth: 3,
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
    );
  }

  Widget _buildQRError() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: GhostColors.redAlpha10,
        shape: Adaptive.surfaceShape(
          radius: 8,
          side: BorderSide(color: GhostColors.redAlpha30),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _qrError!,
              style: GhostTypography.caption.copyWith(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthTab() {
    return SingleChildScrollView(
      physics: Adaptive.scrollPhysics,
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
          // Apple is iOS-only on mobile for now. On Android it would be the
          // browser flow, which AuthService now waits on until the callback
          // lands, but that has not been tested on a device yet and this
          // screen has no Cancel for it. See tasks/todo.md.
          RepaintBoundary(
            child: SocialSignInButtons(
              enabled: !_authLoading,
              showApple: Platform.isIOS,
              onApple: _handleAppleAuth,
              onGoogle: _handleGoogleAuth,
            ),
          ),
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
          borderSide: const BorderSide(color: GhostColors.primary, width: 2),
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
          borderSide: const BorderSide(color: GhostColors.primary, width: 2),
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
      decoration: ShapeDecoration(
        color: GhostColors.redAlpha10,
        shape: Adaptive.surfaceShape(
          radius: 8,
          side: BorderSide(color: GhostColors.redAlpha30),
        ),
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
            ? Adaptive.progressIndicator(color: Colors.white)
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

  /// Turn a link-token exchange failure into something worth reading.
  ///
  /// functions_client throws [FunctionsHttpException] for any non-2xx rather
  /// than returning it, so the server's `code` lives in `details` - not in a
  /// response the caller can inspect. Without unpacking it the user saw raw
  /// exception text and the whole point of the server distinguishing a wrong
  /// PIN from an expired code was lost.
  String _describeExchangeError(Object error) {
    if (error is FunctionsHttpException) {
      final details = error.details;
      final code = details is Map ? details['code'] as String? : null;
      switch (code) {
        case 'invalid_pin':
          return 'Incorrect PIN. Check the code on your other device and '
              'try again.';
        case 'expired':
          return 'This code has expired or was already used. Generate a new '
              'QR code on your other device.';
      }
      final message = details is Map ? details['error'] as String? : null;
      if (message != null && message.isNotEmpty) return message;
      return 'Could not link this device. Please try again.';
    }
    return error.toString().replaceAll('Exception: ', '');
  }

  /// Ask for the 6-digit PIN shown on the sending device.
  ///
  /// Returns null if the user cancels. A wrong PIN does not consume the link
  /// token server-side, so retrying does not require a new QR code.
  Future<String?> _promptForPin() async {
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          String? error;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              void submit() {
                final value = controller.text.trim();
                if (!RegExp(r'^\d{6}$').hasMatch(value)) {
                  setDialogState(() => error = 'Enter the 6 digits');
                  return;
                }
                Navigator.of(context).pop(value);
              }

              return AlertDialog(
                backgroundColor: GhostColors.surface,
                title: const Text(
                  'Enter PIN',
                  style: TextStyle(color: GhostColors.textPrimary),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Type the 6-digit PIN shown next to the QR code on your '
                      'other device.',
                      style: GhostTypography.caption.copyWith(
                        color: GhostColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: GhostColors.textPrimary,
                        fontSize: 24,
                        letterSpacing: 8,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        counterText: '',
                        errorText: error,
                        hintText: '000000',
                        hintStyle: const TextStyle(
                          color: GhostColors.textMuted,
                          letterSpacing: 8,
                        ),
                      ),
                      onSubmitted: (_) => submit(),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(onPressed: submit, child: const Text('Link')),
                ],
              );
            },
          );
        },
      );
    } finally {
      controller.dispose();
    }
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
        throw Exception(
          'Invalid QR code format. Please scan a GhostCopy QR code.',
        );
      }

      // Validate QR data structure
      if (!qrData.containsKey('link_token') || !qrData.containsKey('version')) {
        throw Exception('Invalid QR code: missing required fields.');
      }

      final linkToken = qrData['link_token'] as String?;

      if (linkToken == null || linkToken.isEmpty) {
        throw Exception('Invalid QR code: missing token.');
      }

      // The QR is useless without the PIN shown on the sending device. A wrong
      // PIN does not consume the token, so the user can simply retype it.
      if (!mounted) return;
      final pin = await _promptForPin();
      if (pin == null) {
        // Cancelled - drop out of scanning state without an error.
        if (mounted) setState(() => _qrScanning = false);
        return;
      }

      debugPrint('[QR] Exchanging link token...');

      // Call edge function to exchange token for session
      final response = await supabase.functions.invoke(
        'exchange-link-token',
        body: {'token': linkToken, 'pin': pin},
      );

      // Note: functions_client throws FunctionsHttpException for any non-2xx,
      // so this only catches a 2xx with an empty body. The error codes the
      // server sends (invalid_pin / expired) arrive as that exception instead
      // and are unpacked in the catch below.
      if (response.data == null) {
        throw Exception('Failed to authenticate');
      }

      final data = response.data as Map<String, dynamic>;
      // Nullable cast: this used to be `as String`, and when the server
      // returned no tokens the resulting TypeError was an Error, not an
      // Exception - so `on Exception catch` below never caught it, the scanner
      // hung on a spinner forever, and the single-use token was already gone.
      final refreshToken = data['refresh_token'] as String?;
      if (refreshToken == null || refreshToken.isEmpty) {
        throw Exception(
          'The server did not return a session. Please generate a new QR code.',
        );
      }

      debugPrint('[QR] ✅ Got session tokens, setting session...');

      // Preserve the previous account until the new session is established.
      await locator<IAuthService>().signInWithRefreshToken(refreshToken);

      debugPrint('[QR] ✅ Session set');

      // The QR deliberately no longer carries the passphrase - it used to be
      // "encrypted" with a key placed in the same payload, so a photograph of
      // the screen yielded it outright. If the account has encrypted clips,
      // history shows a prompt to enter the passphrase by hand.

      // Register device and update FCM token
      if (mounted) {
        final fcmToken = await widget.fcmTokenFuture;
        await locator<IDeviceService>().registerCurrentDevice(
          fcmToken: fcmToken,
        );
        if (fcmToken != null) {
          debugPrint('[QR] ✅ Device registered with FCM token');
        }

        debugPrint('[QR] ✅ QR authentication complete');
        widget.onAuthComplete();
      }
    } on Object catch (e) {
      // Catch Object, not Exception: a failed cast throws TypeError, which is
      // an Error. Catching only Exception left the scanner spinning forever on
      // exactly the failure that happened most often.
      if (mounted) {
        setState(() {
          _qrError = _describeExchangeError(e);
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
        // Same guard the desktop panel uses. Without it this screen signed
        // into another account with no prompt, stranding the guest clips -
        // and this is the surface most likely to be holding them.
        // Orphaned rather than deleted on the email path.
        if (!await confirmGuestClipsBeforeSignIn(
          context,
          authService: locator<IAuthService>(),
          deletesClips: false,
        )) {
          if (mounted) setState(() => _authLoading = false);
          return;
        }

        // Sign in with new account (no captcha on mobile)
        await locator<IAuthService>().signInWithEmail(
          _emailController.text,
          _passwordController.text,
        );
      } else {
        // Upgrade anonymous to permanent account
        await locator<IAuthService>().upgradeWithEmail(
          _emailController.text,
          _passwordController.text,
        );
      }

      // Success - register device with FCM token before navigating
      if (mounted) {
        // Auto-restore passphrase from cloud backup if available
        final userId = locator<IAuthService>().currentUserId;
        if (userId != null) {
          final encryptionService = EncryptionService.instance;
          await encryptionService.initialize(userId);
          final restored = await encryptionService.autoRestoreFromCloud();
          if (restored) {
            debugPrint(
              '[Mobile] ✅ Encryption passphrase auto-restored from cloud',
            );
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Encryption passphrase restored from cloud'),
                  backgroundColor: GhostColors.success,
                  duration: Duration(seconds: 3),
                ),
              );
            }
          }
        }

        // Register device
        await locator<IDeviceService>().registerCurrentDevice();

        // Update FCM token if available
        final fcmToken = await widget.fcmTokenFuture;
        if (fcmToken != null) {
          await locator<IDeviceService>().updateFcmToken(fcmToken);
          debugPrint(
            '[Mobile] ✅ Device registered with FCM token after email auth',
          );
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

  Future<void> _handleGoogleAuth() => _handleProviderAuth(
    provider: 'Google',
    signIn: () => locator<IAuthService>().signInWithGoogle(),
    link: () => locator<IAuthService>().linkGoogleIdentity(),
  );

  Future<void> _handleAppleAuth() => _handleProviderAuth(
    provider: 'Apple',
    signIn: () => locator<IAuthService>().signInWithApple(),
    link: () => locator<IAuthService>().linkAppleIdentity(),
  );

  /// Sign in to an existing account ([signIn]) or, in Sign Up mode, upgrade
  /// the anonymous account in place ([link]) with a third-party provider.
  Future<void> _handleProviderAuth({
    required String provider,
    required Future<bool> Function() signIn,
    required Future<bool> Function() link,
  }) async {
    setState(() {
      _authLoading = true;
      _authError = null;
    });

    try {
      final bool success;

      if (_isLogin) {
        // deletesClips: AuthService._cleanupPreviousSession runs
        // cleanup_user_data against the outgoing anonymous account on this
        // path, so the clips are destroyed rather than merely stranded.
        if (!await confirmGuestClipsBeforeSignIn(
          context,
          authService: locator<IAuthService>(),
          deletesClips: true,
        )) {
          if (mounted) setState(() => _authLoading = false);
          return;
        }

        success = await signIn();
      } else {
        // Sign Up mode: upgrade the anonymous user, keeping user_id and clips
        success = await link();
      }

      if (mounted) {
        if (success) {
          // Auto-restore passphrase from cloud backup if available
          final userId = locator<IAuthService>().currentUserId;
          if (userId != null) {
            final encryptionService = EncryptionService.instance;
            await encryptionService.initialize(userId);
            final restored = await encryptionService.autoRestoreFromCloud();
            if (restored) {
              debugPrint(
                '[Mobile] ✅ Encryption passphrase auto-restored from cloud',
              );
              // Show a toast/snackbar to inform user
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Encryption passphrase restored from cloud'),
                    backgroundColor: GhostColors.success,
                    duration: Duration(seconds: 3),
                  ),
                );
              }
            }
          }

          // Success - register the device and its push token in one write
          // before navigating.
          final fcmToken = await widget.fcmTokenFuture;
          await locator<IDeviceService>().registerCurrentDevice(
            fcmToken: fcmToken,
          );
          debugPrint('[Mobile] ✅ Device registered after $provider auth');

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
      final success = await locator<IAuthService>().sendPasswordResetEmail(
        email,
      );

      if (mounted) {
        setState(() => _authLoading = false);

        if (success) {
          // Show success message
          if (mounted) {
            unawaited(
              showDialog<void>(
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
}
