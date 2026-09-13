import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../locator.dart';
import '../../main.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/settings_service.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/passphrase_dialog.dart';
import 'mobile_welcome_screen.dart';

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
    required this.settingsService,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final ISettingsService settingsService;

  @override
  State<MobileSettingsScreen> createState() => _MobileSettingsScreenState();
}



class _MobileSettingsScreenState extends State<MobileSettingsScreen> {
  // Device list state
  List<Device> _devices = [];
  bool _devicesLoading = false;

  // Encryption state
  EncryptionService? _encryptionService;
  bool _encryptionEnabled = false;
  bool _encryptionLoading = false;
  bool _hasBackup = false;

  // Clipboard auto-clear state
  int _autoClearSeconds = 30;
  bool _autoClearLoading = false;

  // URL shortening state
  bool _autoShortenUrls = false;
  bool _urlShortenerLoading = false;

  // App info
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _initializeEncryption();
    _loadDevices();
    _loadAppInfo();
    _loadAutoClearSetting();
    _loadUrlShorteningStatus();
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

      var enabled = await _encryptionService!.isEnabled();
      var hasBackup = false;

      // Check for backup if encryption is disabled
      if (!enabled) {
        hasBackup = await _encryptionService!.hasCloudBackup();
        
        // Auto-restore attempt on load (same as desktop)
        if (hasBackup) {
          try {
            final restored = await _encryptionService!.autoRestoreFromCloud();
            if (restored) {
              enabled = true;
            }
          } on Exception catch (e) {
            debugPrint('[MobileSettings] Auto-restore on load failed: $e');
          }
        }
      }

      if (mounted) {
        setState(() {
          _encryptionEnabled = enabled;
          _hasBackup = hasBackup;
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

      // Re-register device + FCM token for new anonymous user
      // signOut() signs in anonymously, so current user has a new user_id
      try {
        await widget.deviceService.registerCurrentDevice();
        final fcmToken = await FirebaseMessaging.instance.getToken();
        if (fcmToken != null) {
          await widget.deviceService.updateFcmToken(fcmToken);
        }
        debugPrint('[Settings] ✅ Device re-registered after sign out');
      } on Exception catch (e) {
        debugPrint('[Settings] ⚠️ Failed to re-register device: $e');
      }

      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  /// Open the welcome screen so an anonymous user can sign in, create an
  /// account, or link this device by QR.
  ///
  /// The welcome screen is normally only reached at launch (main.dart gates it
  /// on _mobileAuthComplete), so after a sign-out there was no path back to it.
  Future<void> _handleSignIn() async {
    final userBefore = widget.authService.currentUserId;

    await Navigator.of(context).push(
      Adaptive.pageRoute<void>(
        builder: (context) => MobileWelcomeScreen(
          onAuthComplete: () {
            // Close the welcome screen; settings re-reads state below.
            Navigator.of(context).pop();
          },
        ),
      ),
    );

    if (!mounted) return;

    // The account may now be a different one: re-read everything that is
    // scoped to the user rather than leaving the previous account's state on
    // screen.
    if (widget.authService.currentUserId != userBefore) {
      debugPrint('[MobileSettings] Account changed after sign-in');
      await _initializeEncryption();
      await _loadDevices();
    }

    if (mounted) setState(() {});
  }

  Future<void> _handleEncryptionToggle(bool enabled) async {
    if (_encryptionService == null) return;

    if (enabled) {
      final userId = widget.authService.currentUserId;
      if (userId == null) return;
      
      // If we have a backup, try restore flow first
      if (_hasBackup) {
        await _restoreFromBackup();
        return; // _restoreFromBackup handles UI updates
      }

      // If this account already has encrypted clips that this device cannot
      // read, the user needs to ENTER their existing passphrase - not invent a
      // new one. Offering Set mode here is what produced mismatched keys and
      // InvalidCipherTextException on every clip.
      final repo = locator<IClipboardRepository>();
      final hasExistingEncrypted = repo.undecryptableItemCount.value > 0;

      final success = await showPassphraseDialog(
        context,
        _encryptionService!,
        userId,
        isRestoreMode: hasExistingEncrypted,
      );

      if (!success || !mounted) return;

      // Verify against real data. setPassphrase() accepts anything, so only
      // actually decrypting a clip proves the passphrase is right.
      //
      // The test is whether the locked count DROPPED, not whether it reached
      // zero. History can legitimately contain clips encrypted under several
      // different passphrases - anything from before a passphrase change, or
      // from another device that had a different one - and those stay locked
      // forever by design. Requiring zero rejected correct passphrases
      // whenever any older clip was unopenable.
      if (hasExistingEncrypted) {
        final lockedBefore = repo.undecryptableItemCount.value;
        setState(() => _encryptionLoading = true);
        await repo.getHistory();
        if (!mounted) return;

        final lockedAfter = repo.undecryptableItemCount.value;
        debugPrint(
          '[MobileSettings] Passphrase check: locked $lockedBefore -> '
          '$lockedAfter',
        );

        if (lockedAfter >= lockedBefore) {
          await _encryptionService!.clearPassphrase();
          if (!mounted) return;
          setState(() {
            _encryptionEnabled = false;
            _encryptionLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'That passphrase did not unlock any of your clips',
              ),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }

        setState(() => _encryptionLoading = false);

        if (lockedAfter > 0) {
          // Partial success is the expected outcome after a passphrase change.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${lockedBefore - lockedAfter} clip(s) unlocked. $lockedAfter '
                'still use a different passphrase.',
              ),
              backgroundColor: GhostColors.success,
            ),
          );
          setState(() => _encryptionEnabled = true);
          return;
        }
      }

      setState(() => _encryptionEnabled = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasExistingEncrypted
                ? 'Passphrase accepted - your clips are unlocked'
                : 'Encryption enabled',
          ),
          backgroundColor: GhostColors.success,
        ),
      );
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

  Future<void> _restoreFromBackup() async {
    if (_encryptionService == null) return;

    // Show loading indicator
    setState(() => _encryptionLoading = true);

    try {
      // 1. Attempt auto-restore
      final success = await _encryptionService!.autoRestoreFromCloud();
      
      if (mounted) {
        setState(() => _encryptionLoading = false);
        
        if (success) {
          setState(() => _encryptionEnabled = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Passphrase restored!')),
          );
        } else {
          // 2. Fallback to manual entry
          final userId = widget.authService.currentUserId;
          if (userId != null) {
            final manualSuccess = await showPassphraseDialog(
              context,
              _encryptionService!,
              userId,
              isRestoreMode: true,
            );
            
            if (manualSuccess && mounted) {
              setState(() => _encryptionEnabled = true);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Passphrase restored manually!')),
              );
            }
          }
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _encryptionLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
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
    return Adaptive.confirm(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
      isDestructive: isDestructive,
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
        physics: Adaptive.scrollPhysics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(300),
        children: [
          // Features section (moved to top)
          _buildSectionHeader('Features'),
          _buildFeaturesSection(),

          const SizedBox(height: 24),

          // Devices section
          _buildSectionHeader('Devices'),
          _buildDevicesSection(),

          const SizedBox(height: 24),

          // Security section
          _buildSectionHeader('Security'),
          _buildSecuritySection(),

          const SizedBox(height: 24),

          // Account section (moved to bottom)
          _buildSectionHeader('Account'),
          _buildAccountSection(),

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
              backgroundColor: GhostColors.primaryAlpha20,
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

          // Anonymous users need a route back to sign-in. Signing out drops the
          // user onto a fresh temporary account, and the welcome screen is only
          // shown at launch - so without this there was no way to sign in again
          // or link to an existing account short of reinstalling.
          if (isAnonymous)
            ListTile(
              leading: const Icon(
                Icons.login,
                color: GhostColors.primary,
                size: 20,
              ),
              title: const Text(
                'Sign In or Create Account',
                style: TextStyle(fontSize: 14, color: GhostColors.textPrimary),
              ),
              subtitle: const Text(
                'Scan a QR code from another device, or use email',
                style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: GhostColors.textMuted,
                size: 20,
              ),
              onTap: _handleSignIn,
            ),

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
          ? Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Adaptive.progressIndicator(
                  size: 32,
                  strokeWidth: 3,
                  color: GhostColors.primary,
                ),
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

  Future<void> _loadAutoClearSetting() async {
    setState(() => _autoClearLoading = true);
    try {
      final seconds = await widget.settingsService.getClipboardAutoClearSeconds();
      if (mounted) {
        setState(() {
          _autoClearSeconds = seconds;
          _autoClearLoading = false;
        });
      }
    } on Exception catch (e) {
      debugPrint('Failed to load auto-clear setting: $e');
      if (mounted) {
        setState(() => _autoClearLoading = false);
      }
    }
  }

  Future<void> _loadUrlShorteningStatus() async {
    setState(() => _urlShortenerLoading = true);
    try {
      final enabled = await widget.settingsService.getAutoShortenUrls();
      if (mounted) {
        setState(() {
          _autoShortenUrls = enabled;
          _urlShortenerLoading = false;
        });
      }
    } on Exception catch (e) {
      debugPrint('Failed to load URL shortening setting: $e');
      if (mounted) {
        setState(() => _urlShortenerLoading = false);
      }
    }
  }

  Future<void> _handleUrlShorteningToggle(bool enabled) async {
    setState(() => _urlShortenerLoading = true);
    try {
      await widget.settingsService.setAutoShortenUrls(enabled: enabled);
      if (mounted) {
        setState(() {
          _autoShortenUrls = enabled;
          _urlShortenerLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'URL shortening enabled'
                  : 'URL shortening disabled',
            ),
            backgroundColor: GhostColors.success,
          ),
        );
      }
    } on Exception catch (e) {
      debugPrint('Failed to update URL shortening setting: $e');
      if (mounted) {
        setState(() => _urlShortenerLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to update setting'),
            backgroundColor: Colors.red.shade400,
          ),
        );
      }
    }
  }

  Future<void> _handleAutoClearChange(int? newValue) async {
    if (newValue == null) return;

    setState(() => _autoClearLoading = true);
    try {
      await widget.settingsService.setClipboardAutoClearSeconds(newValue);
      if (mounted) {
        setState(() {
          _autoClearSeconds = newValue;
          _autoClearLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newValue == 0
                  ? 'Clipboard auto-clear disabled'
                  : 'Clipboard will auto-clear after $newValue seconds',
            ),
            backgroundColor: GhostColors.success,
          ),
        );
      }
    } on Exception catch (e) {
      debugPrint('Failed to update auto-clear setting: $e');
      if (mounted) {
        setState(() => _autoClearLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to update setting'),
            backgroundColor: Colors.red.shade400,
          ),
        );
      }
    }
  }

  Widget _buildFeaturesSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: Column(
        children: [
          // URL shortening toggle
          SwitchListTile.adaptive(
            secondary: const Icon(
              Icons.link,
              color: GhostColors.primary,
              size: 20,
            ),
            title: const Text(
              'Auto-Shorten URLs',
              style: TextStyle(fontSize: 14, color: GhostColors.textPrimary),
            ),
            subtitle: const Text(
              'Automatically shorten long URLs before sending',
              style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
            ),
            value: _autoShortenUrls,
            activeTrackColor: GhostColors.success,
            onChanged: _urlShortenerLoading ? null : _handleUrlShorteningToggle,
          ),

        ],
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
      child: Column(
        children: [
          // Encryption toggle
          SwitchListTile.adaptive(
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

          // Explicit "Restore" button if has backup but currently disabled
          if (!_encryptionEnabled && _hasBackup) ...[
            const Divider(height: 1, color: GhostColors.glassBorder),
            ListTile(
              leading: const Icon(
                Icons.restore,
                color: GhostColors.primary,
                size: 20,
              ),
              title: const Text(
                'Restore from Backup',
                style: TextStyle(
                  fontSize: 14,
                  color: GhostColors.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: const Text(
                'Unlock history using your existing passphrase',
                style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
              ),
              onTap: _encryptionLoading ? null : _restoreFromBackup,
            ),
          ],

          const Divider(height: 1, color: GhostColors.glassBorder),

          // Clipboard auto-clear dropdown
          ListTile(
            leading: const Icon(
              Icons.auto_delete,
              color: GhostColors.primary,
              size: 20,
            ),
            title: const Text(
              'Auto-Clear Clipboard',
              style: TextStyle(fontSize: 14, color: GhostColors.textPrimary),
            ),
            subtitle: const Text(
              'Clear clipboard after sending for security',
              style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
            ),
            trailing: _autoClearLoading
                ? Adaptive.progressIndicator()
                : DropdownButton<int>(
                    value: _autoClearSeconds,
                    dropdownColor: GhostColors.surface,
                    style: const TextStyle(
                      color: GhostColors.textPrimary,
                      fontSize: 13,
                    ),
                    underline: Container(),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Off')),
                      DropdownMenuItem(value: 5, child: Text('5s')),
                      DropdownMenuItem(value: 10, child: Text('10s')),
                      DropdownMenuItem(value: 30, child: Text('30s')),
                      DropdownMenuItem(value: 60, child: Text('60s')),
                    ],
                    onChanged: _handleAutoClearChange,
                  ),
          ),
        ],
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
            color: GhostColors.primaryAlpha20,
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
