import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../main.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Mobile settings screen
///
/// Features:
/// - Account management (sign in/out, upgrade)
/// - QR code scanner for anonymous account linking
/// - Device management
/// - Encryption toggle
/// - App version info
///
/// Performance:
/// - Lazy loading of device list
/// - Proper disposal of all controllers
/// - RepaintBoundary around expensive widgets
class MobileSettingsScreen extends StatefulWidget {
  const MobileSettingsScreen({
    required this.authService,
    required this.deviceService,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;

  @override
  State<MobileSettingsScreen> createState() => _MobileSettingsScreenState();
}

/// Stateful passphrase dialog with validation
class _PassphraseDialogWidget extends StatefulWidget {
  const _PassphraseDialogWidget({required this.isSetup});

  final bool isSetup;

  @override
  State<_PassphraseDialogWidget> createState() =>
      _PassphraseDialogWidgetState();
}

class _PassphraseDialogWidgetState extends State<_PassphraseDialogWidget> {
  final _controller = TextEditingController();
  String? _errorMessage;
  static const int _minLength = 8;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final passphrase = _controller.text.trim();

    // Validate passphrase
    if (passphrase.isEmpty) {
      setState(() => _errorMessage = 'Passphrase cannot be empty');
      return;
    }

    if (passphrase.length < _minLength) {
      setState(
        () => _errorMessage =
            'Passphrase must be at least $_minLength characters',
      );
      return;
    }

    // Valid - return passphrase
    Navigator.of(context).pop(passphrase);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GhostColors.surface,
      title: Text(
        widget.isSetup ? 'Set Encryption Passphrase' : 'Enter Passphrase',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: GhostColors.textPrimary,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            style: const TextStyle(color: GhostColors.textPrimary),
            decoration: InputDecoration(
              hintText: 'At least $_minLength characters',
              hintStyle: TextStyle(
                color: GhostColors.textMuted.withValues(alpha: 0.6),
              ),
              filled: true,
              fillColor: GhostColors.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              errorText: _errorMessage,
              errorStyle: const TextStyle(color: Colors.red, fontSize: 12),
            ),
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              // Clear error when user types
              if (_errorMessage != null) {
                setState(() => _errorMessage = null);
              }
            },
          ),
          if (widget.isSetup) ...[
            const SizedBox(height: 12),
            Text(
              '⚠️ If you lose your passphrase, encrypted data cannot be recovered.',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade300),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(backgroundColor: GhostColors.primary),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

class _MobileSettingsScreenState extends State<MobileSettingsScreen> {
  // Device list state
  List<Device> _devices = [];
  bool _devicesLoading = false;

  // Encryption state
  EncryptionService? _encryptionService;
  bool _encryptionEnabled = false;
  bool _encryptionLoading = false;

  // App info
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _initializeEncryption();
    _loadDevices();
    _loadAppInfo();
  }

  @override
  void dispose() {
    // NOTE: EncryptionService is a singleton - do NOT dispose it here
    super.dispose();
  }

  Future<void> _initializeEncryption() async {
    final userId = widget.authService.currentUserId;
    if (userId != null) {
      setState(() => _encryptionLoading = true);

      // Use shared singleton instance
      _encryptionService = EncryptionService.instance;
      await _encryptionService!.initialize(userId);

      final enabled = await _encryptionService!.isEnabled();

      if (mounted) {
        setState(() {
          _encryptionEnabled = enabled;
          _encryptionLoading = false;
        });
      }
    }
  }

  Future<void> _loadDevices() async {
    setState(() => _devicesLoading = true);

    try {
      final devices = await widget.deviceService.getUserDevices(
        forceRefresh: true,
      );
      if (mounted) {
        setState(() {
          _devices = devices;
          _devicesLoading = false;
        });
      }
    } on Exception catch (e) {
      debugPrint('[Settings] Failed to load devices: $e');
      if (mounted) {
        setState(() => _devicesLoading = false);
      }
    }
  }

  Future<void> _loadAppInfo() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = 'v${packageInfo.version}+${packageInfo.buildNumber}';
        });
      }
    } on Exception catch (e) {
      debugPrint('[Settings] Failed to load app info: $e');
    }
  }

  Future<void> _handleSignOut() async {
    final confirmed = await _showConfirmDialog(
      title: 'Sign Out',
      message:
          'Are you sure you want to sign out? You will need to sign in again to access your clipboard history.',
      confirmText: 'Sign Out',
      isDestructive: true,
    );

    if (confirmed) {
      await widget.authService.signOut();
      if (mounted) {
        // Pop back to welcome screen (handled by main.dart state change)
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _handleEncryptionToggle(bool enabled) async {
    if (_encryptionService == null) return;

    if (enabled) {
      // Show passphrase setup dialog
      final passphrase = await _showPassphraseDialog(isSetup: true);
      if (passphrase != null) {
        setState(() => _encryptionLoading = true);

        final success = await _encryptionService!.setPassphrase(passphrase);

        if (mounted) {
          setState(() {
            _encryptionEnabled = success;
            _encryptionLoading = false;
          });

          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Encryption enabled'),
                backgroundColor: GhostColors.success,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Failed to enable encryption'),
                backgroundColor: Colors.red.shade400,
              ),
            );
          }
        }
      }
    } else {
      // Disable encryption
      final confirmed = await _showConfirmDialog(
        title: 'Disable Encryption?',
        message:
            'This will disable encryption for new clipboard items. Existing encrypted items will remain encrypted.',
        confirmText: 'Disable',
        isDestructive: true,
      );

      if (confirmed) {
        setState(() => _encryptionLoading = true);
        await _encryptionService!.clearPassphrase();
        if (mounted) {
          setState(() {
            _encryptionEnabled = false;
            _encryptionLoading = false;
          });
        }
      }
    }
  }

  Future<void> _handleRemoveDevice(String deviceId, String deviceName) async {
    final confirmed = await _showConfirmDialog(
      title: 'Remove Device',
      message:
          'Remove "$deviceName" from your account? This device will no longer receive clipboard items.',
      confirmText: 'Remove',
      isDestructive: true,
    );

    if (confirmed) {
      final success = await widget.deviceService.removeDevice(deviceId);

      if (mounted) {
        if (success) {
          setState(() {
            _devices = _devices.where((d) => d.id != deviceId).toList();
          });

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Device removed'),
              backgroundColor: GhostColors.success,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Failed to remove device'),
              backgroundColor: Colors.red.shade400,
            ),
          );
        }
      }
    }
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String message,
    required String confirmText,
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GhostColors.surface,
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: GhostColors.textPrimary,
          ),
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, color: GhostColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: isDestructive
                  ? Colors.red.shade400
                  : GhostColors.primary,
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<String?> _showPassphraseDialog({bool isSetup = false}) async {
    return showDialog<String>(
      context: context,
      builder: (context) => _PassphraseDialogWidget(isSetup: isSetup),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GhostColors.background,
      appBar: AppBar(
        backgroundColor: GhostColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
          color: GhostColors.textPrimary,
        ),
        title: Text(
          'Settings',
          style: GhostTypography.headline.copyWith(fontSize: 18),
        ),
      ),
      body: ListView(
        children: [
          // Account section
          _buildSectionHeader('Account'),
          _buildAccountSection(),

          const SizedBox(height: 24),

          // Devices section
          _buildSectionHeader('Devices'),
          _buildDevicesSection(),

          const SizedBox(height: 24),

          // Security section
          _buildSectionHeader('Security'),
          _buildSecuritySection(),

          const SizedBox(height: 24),

          // About section
          _buildSectionHeader('About'),
          _buildAboutSection(),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text(
        title,
        style: GhostTypography.caption.copyWith(
          color: GhostColors.textMuted,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildAccountSection() {
    final user = supabase.auth.currentUser;
    final isAnonymous = widget.authService.isAnonymous;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: Column(
        children: [
          // User info
          ListTile(
            leading: CircleAvatar(
              backgroundColor: GhostColors.primary.withValues(alpha: 0.2),
              child: Icon(
                isAnonymous ? Icons.person_outline : Icons.person,
                color: GhostColors.primary,
                size: 20,
              ),
            ),
            title: Text(
              user?.email ?? 'Anonymous User',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: GhostColors.textPrimary,
              ),
            ),
            subtitle: Text(
              isAnonymous ? 'Temporary account' : 'Signed in',
              style: const TextStyle(
                fontSize: 12,
                color: GhostColors.textMuted,
              ),
            ),
          ),

          const Divider(height: 1, color: GhostColors.glassBorder),

          // Sign out button (only for authenticated users)
          if (!isAnonymous)
            ListTile(
              leading: Icon(Icons.logout, color: Colors.red.shade400, size: 20),
              title: Text(
                'Sign Out',
                style: TextStyle(fontSize: 14, color: Colors.red.shade400),
              ),
              onTap: _handleSignOut,
            ),
        ],
      ),
    );
  }

  Widget _buildDevicesSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: _devicesLoading
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: GhostColors.primary),
              ),
            )
          : _devices.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No devices registered',
                  style: TextStyle(fontSize: 13, color: GhostColors.textMuted),
                ),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _devices.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, color: GhostColors.glassBorder),
              itemBuilder: (context, index) {
                final device = _devices[index];
                final isCurrent =
                    device.id == widget.deviceService.getCurrentDeviceId();

                return ListTile(
                  leading: Icon(
                    _getDeviceIcon(device.deviceType),
                    color: GhostColors.primary,
                    size: 20,
                  ),
                  title: Row(
                    children: [
                      Text(
                        device.displayName,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: GhostColors.success.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'This device',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: GhostColors.success,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    _capitalizeFirst(device.deviceType),
                    style: const TextStyle(
                      fontSize: 12,
                      color: GhostColors.textMuted,
                    ),
                  ),
                  trailing: !isCurrent
                      ? IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            color: Colors.red.shade400,
                            size: 20,
                          ),
                          onPressed: () => _handleRemoveDevice(
                            device.id,
                            device.displayName,
                          ),
                        )
                      : null,
                );
              },
            ),
    );
  }

  Widget _buildSecuritySection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: SwitchListTile(
        secondary: const Icon(
          Icons.lock_outline,
          color: GhostColors.primary,
          size: 20,
        ),
        title: const Text(
          'End-to-End Encryption',
          style: TextStyle(fontSize: 14, color: GhostColors.textPrimary),
        ),
        subtitle: const Text(
          'Encrypt clipboard items with a passphrase',
          style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
        ),
        value: _encryptionEnabled,
        activeTrackColor: GhostColors.success,
        onChanged: _encryptionLoading ? null : _handleEncryptionToggle,
      ),
    );
  }

  Widget _buildAboutSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: ListTile(
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: GhostColors.primary.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.content_copy_rounded,
            size: 18,
            color: GhostColors.primary,
          ),
        ),
        title: const Text(
          'GhostCopy',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: GhostColors.textPrimary,
          ),
        ),
        subtitle: Text(
          _appVersion.isEmpty ? 'Loading...' : _appVersion,
          style: const TextStyle(fontSize: 12, color: GhostColors.textMuted),
        ),
      ),
    );
  }

  IconData _getDeviceIcon(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'windows':
        return Icons.laptop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.laptop_chromebook;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }

  String _capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }
}
