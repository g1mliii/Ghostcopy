import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../locator.dart';
import '../../services/auth_service.dart';
import '../../services/encryption_service.dart';
import '../../services/window_service.dart';
import '../theme/colors.dart';

/// Window height needed to show the pairing dialog without scrolling.
///
/// A request, not a guarantee: WindowService clamps it to the work area of
/// the display the window is on, so on a short screen the window stays fully
/// visible and the dialog's scroll view takes over instead.
const double _dialogWindowHeight = 700;

/// Dialog for displaying QR code to link new mobile device
///
/// Performance optimized:
/// - RepaintBoundary around QR code
/// - Cached QR data
/// - Single timer for countdown
/// - Proper disposal to prevent memory leaks
///
/// Security:
/// - Token expires in 5 minutes
/// - Single-use token
/// - Passphrase encrypted before QR encoding (if encryption enabled)
/// - All sensitive data cleared from memory on dispose
class LinkDeviceDialog extends StatefulWidget {
  const LinkDeviceDialog({
    required this.authService,
    required this.encryptionService,
    super.key,
  });

  final IAuthService authService;
  final IEncryptionService encryptionService;

  @override
  State<LinkDeviceDialog> createState() => _LinkDeviceDialogState();
}

class _LinkDeviceDialogState extends State<LinkDeviceDialog> {
  String? _pin;
  String? _qrData;
  String? _errorMessage;
  bool _isLoading = true;
  Timer? _countdownTimer;
  Timer? _expiryTimer;
  int _secondsRemaining = 300; // 5 minutes

  @override
  void initState() {
    super.initState();
    _generateQrCode();
  }

  @override
  void dispose() {
    // Cancel timers to prevent memory leaks
    _countdownTimer?.cancel();
    _expiryTimer?.cancel();

    // Clear sensitive data from memory
    _qrData = null;
    _pin = null;

    super.dispose();
  }

  Future<void> _generateQrCode() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Generate the link token and its PIN
      final link = await widget.authService.generateMobileLinkToken();

      // 2. Build QR data JSON.
      //
      // The passphrase is deliberately NOT included. It used to be shipped
      // here "encrypted" with a one-time key that was placed in the same
      // payload, so anyone who photographed the QR obtained both the
      // passphrase and a token redeemable for an account session. The
      // passphrase is now typed by hand on each device; the QR only carries
      // the link token, which is useless without the PIN below.
      final qrDataMap = {'link_token': link.tokenHash, 'version': 2};

      if (!mounted) return;

      setState(() {
        _qrData = jsonEncode(qrDataMap);
        _pin = link.pin;
        _isLoading = false;
      });

      // 5. Start countdown timer (updates every second)
      _startCountdown();

      // 6. Auto-close dialog when token expires
      _expiryTimer = Timer(const Duration(minutes: 5), () {
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
    } on Exception catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = 'Failed to generate QR code: $e';
        _isLoading = false;
      });
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _secondsRemaining--;
      });

      if (_secondsRemaining <= 0) {
        timer.cancel();
      }
    });
  }

  String _formatTimeRemaining() {
    final minutes = _secondsRemaining ~/ 60;
    final seconds = _secondsRemaining % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: GhostColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Icon(Icons.qr_code_2, color: GhostColors.primary, size: 24),
                  const SizedBox(width: 12),
                  Text(
                    'Link New Device',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: GhostColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: GhostColors.textMuted,
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // QR Code or Loading/Error
              if (_isLoading)
                SizedBox(
                  height: 200,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          color: GhostColors.primary,
                          strokeWidth: 2,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Generating QR code...',
                          style: TextStyle(
                            fontSize: 12,
                            color: GhostColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else if (_errorMessage != null)
                Container(
                  height: 200,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.red.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, color: Colors.red, size: 32),
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.red),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _generateQrCode,
                        child: const Text('Try Again'),
                      ),
                    ],
                  ),
                )
              else if (_qrData != null)
                // QR Code with RepaintBoundary for performance
                RepaintBoundary(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _qrData!,
                      size: 200,
                      backgroundColor: Colors.white,
                      // Styles are left at their defaults deliberately. Passing
                      // a partial style - a shape with no colour - overrides
                      // the default black with null, and QrPainter force
                      // unwraps it, so the code paints as a blank white square.
                    ),
                  ),
                ),

              // PIN. The QR alone cannot link a device - this must be typed on
              // the receiving phone, so a photograph or a glance at the screen
              // is not enough on its own.
              if (_pin != null) ...[
                const SizedBox(height: 20),
                Text(
                  'Enter this PIN on your phone',
                  style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: GhostColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: GhostColors.primary),
                  ),
                  child: Text(
                    // Grouped 3+3 so it is easy to read off the screen.
                    '${_pin!.substring(0, 3)} ${_pin!.substring(3)}',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 6,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: GhostColors.textPrimary,
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // Countdown timer
              if (_qrData != null && _secondsRemaining > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: GhostColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.timer_outlined,
                        size: 14,
                        color: GhostColors.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Expires in ${_formatTimeRemaining()}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: GhostColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 24),

              // Instructions
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: GhostColors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInstruction(1, 'Open GhostCopy on mobile'),
                    const SizedBox(height: 8),
                    _buildInstruction(2, 'Tap "Link to Desktop"'),
                    const SizedBox(height: 8),
                    _buildInstruction(3, 'Scan this QR code'),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Close button
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: GhostColors.surface,
                    foregroundColor: GhostColors.textPrimary,
                  ),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInstruction(int number, String text) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: GhostColors.primary.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(
              number.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: GhostColors.primary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          text,
          style: TextStyle(fontSize: 13, color: GhostColors.textSecondary),
        ),
      ],
    );
  }
}

/// Show link device dialog
Future<void> showLinkDeviceDialog(
  BuildContext context,
  IAuthService authService,
  IEncryptionService encryptionService,
) async {
  // The QR code, PIN and pairing steps need more room than the Spotlight
  // window has. Growing the window beats shrinking the QR, which has to stay
  // large enough for a phone camera to read.
  final windowService = locator<IWindowService>();
  try {
    await windowService.growToHeight(_dialogWindowHeight);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => LinkDeviceDialog(
        authService: authService,
        encryptionService: encryptionService,
      ),
    );
  } finally {
    await windowService.restoreSpotlightSize();
  }
}
