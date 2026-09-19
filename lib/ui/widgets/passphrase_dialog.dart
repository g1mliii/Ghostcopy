import 'package:flutter/material.dart';

import '../../models/exceptions.dart';
import '../../services/encryption_service.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';

/// Dialog for setting up encryption passphrase
///
/// Memory-safe implementation:
/// - TextEditingController properly disposed
/// - FocusNode properly disposed
/// - No retained references to sensitive data
/// - Passwords cleared from memory after use
class PassphraseDialog extends StatefulWidget {
  const PassphraseDialog({
    required this.encryptionService,
    required this.userId,
    this.isRestoreMode = false,
    super.key,
  });

  final IEncryptionService encryptionService;
  final String userId;
  final bool isRestoreMode;

  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  // ... existing state ...
  late final TextEditingController _passphraseController;
  late final TextEditingController _confirmController;
  late final FocusNode _passphraseFocus;
  late final FocusNode _confirmFocus;

  bool _obscurePassphrase = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  String? _errorMessage;

  static const int _minLength = 8;

  @override
  void initState() {
    super.initState();
    _passphraseController = TextEditingController();
    _confirmController = TextEditingController();
    _passphraseFocus = FocusNode();
    _confirmFocus = FocusNode();
  }

  @override
  void dispose() {
    // Clear sensitive data from memory before disposing
    _passphraseController.clear();
    _confirmController.clear();

    // Dispose controllers and focus nodes to prevent memory leaks
    _passphraseController.dispose();
    _confirmController.dispose();
    _passphraseFocus.dispose();
    _confirmFocus.dispose();

    super.dispose();
  }

  Future<void> _setPassphrase() async {
    setState(() {
      _errorMessage = null;
      _isLoading = true;
    });

    try {
      final passphrase = _passphraseController.text;
      final confirm = _confirmController.text;

      // Validate passphrase
      if (passphrase.isEmpty) {
        setState(() {
          _errorMessage = 'Passphrase cannot be empty';
          _isLoading = false;
        });
        return;
      }

      if (passphrase.length < _minLength) {
        setState(() {
          _errorMessage = 'Passphrase must be at least $_minLength characters';
          _isLoading = false;
        });
        return;
      }

      // Only check confirmation if NOT in restore mode
      if (!widget.isRestoreMode && passphrase != confirm) {
        setState(() {
          _errorMessage = 'Passphrases do not match';
          _isLoading = false;
        });
        return;
      }

      // Ensure encryption service is initialized before setting passphrase
      await widget.encryptionService.initialize(widget.userId);

      // Set passphrase in encryption service
      final success = await widget.encryptionService.setPassphrase(passphrase);

      if (!mounted) return;

      if (success) {
        // Clear text fields before closing (security)
        _passphraseController.clear();
        _confirmController.clear();

        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _errorMessage = widget.isRestoreMode
              ? 'Failed to restore passphrase. Please try again.'
              : 'Failed to set passphrase. Please try again.';
          _isLoading = false;
        });
      }
    } on PassphraseStorageException catch (e) {
      // Not a passphrase problem, so do not send the user back to re-type one.
      // The device refused to keep it outright.
      //
      // This used to advise reinstalling, on the theory that the cause was a
      // stale Keychain entry from a previous install. It is not advice that
      // works: Keychain items survive app deletion on iOS, so a reinstall
      // meets the same entry again - and setPassphrase now clears that entry
      // under both accessibilities before writing, so it is no longer the
      // likely cause anyway. What is left is a device that genuinely would not
      // store it, where retrying after a restart is the honest suggestion.
      debugPrint(
        '[PassphraseDialog] Secure storage refused the passphrase: $e',
      );
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'This device would not save your passphrase. Your passphrase is '
            'fine and your clips are safe - restart your device and try '
            'again.';
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;

      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.isRestoreMode
            ? 'Enter Encryption Passphrase'
            : 'Set Encryption Passphrase',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isRestoreMode
                  ? 'Enter your existing passphrase to restore access to your encrypted clipboard history.'
                  : 'Protect your clipboard with end-to-end encryption. Your passphrase is stored securely in your system keychain.',
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            if (!widget.isRestoreMode) ...[
              const Text(
                '⚠️ If you lose your passphrase, encrypted data cannot be recovered.',
                style: TextStyle(
                  fontSize: 12,
                  color: GhostColors.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
            ],

            // Passphrase field
            TextField(
              controller: _passphraseController,
              focusNode: _passphraseFocus,
              obscureText: _obscurePassphrase,
              enabled: !_isLoading,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Passphrase',
                hintText: 'At least $_minLength characters',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassphrase
                        ? Icons.visibility
                        : Icons.visibility_off,
                  ),
                  tooltip: _obscurePassphrase
                      ? 'Show passphrase'
                      : 'Hide passphrase',
                  onPressed: () {
                    setState(() {
                      _obscurePassphrase = !_obscurePassphrase;
                    });
                  },
                ),
              ),
              onSubmitted: (_) {
                if (widget.isRestoreMode) {
                  // Submit immediately in restore mode
                  if (!_isLoading) _setPassphrase();
                } else {
                  // Focus confirm field in set mode
                  _confirmFocus.requestFocus();
                }
              },
            ),

            // Confirm passphrase field (only in Set mode)
            if (!widget.isRestoreMode) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _confirmController,
                focusNode: _confirmFocus,
                obscureText: _obscureConfirm,
                enabled: !_isLoading,
                decoration: InputDecoration(
                  labelText: 'Confirm Passphrase',
                  hintText: 'Re-enter passphrase',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirm ? Icons.visibility : Icons.visibility_off,
                    ),
                    tooltip: _obscureConfirm
                        ? 'Show confirmation'
                        : 'Hide confirmation',
                    onPressed: () {
                      setState(() {
                        _obscureConfirm = !_obscureConfirm;
                      });
                    },
                  ),
                ),
                onSubmitted: (_) {
                  if (!_isLoading) {
                    _setPassphrase();
                  }
                },
              ),
            ],

            // Error message
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: GhostColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: GhostColors.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: GhostColors.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: GhostColors.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading
              ? null
              : () {
                  // Clear fields before closing
                  _passphraseController.clear();
                  _confirmController.clear();
                  Navigator.of(context).pop(false);
                },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isLoading ? null : _setPassphrase,
          child: _isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: Adaptive.progressIndicator(size: 16),
                )
              : Text(
                  widget.isRestoreMode ? 'Restore Access' : 'Enable Encryption',
                ),
        ),
      ],
    );
  }
}

/// Show passphrase setup dialog
Future<bool> showPassphraseDialog(
  BuildContext context,
  IEncryptionService encryptionService,
  String userId, {
  bool isRestoreMode = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PassphraseDialog(
      encryptionService: encryptionService,
      userId: userId,
      isRestoreMode: isRestoreMode,
    ),
  );
  return result ?? false;
}
