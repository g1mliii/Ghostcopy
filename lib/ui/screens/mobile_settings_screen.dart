import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../locator.dart';
import '../../main.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/settings_service.dart';
import '../../utils/device_selection.dart';
import '../../utils/platform_label.dart';
import '../device_type_icon.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../widgets/adaptive_switch.dart';
import '../widgets/ghost_toast.dart';
import '../widgets/passphrase_dialog.dart';
import 'mobile_welcome_screen.dart';

/// GhostCopy's public site, shown to the user before they are sent to it.
///
/// Quoted verbatim in the confirmation dialog, so this is read by the user
/// rather than only followed - keep it in step with the deployed domain.
const _websiteUrl = 'https://ghostcopy.app';

/// Shared with MainActivity's NOTIFICATION_CHANNEL. Used here only to toggle
/// FLAG_SECURE live; the native side re-reads the stored preference at launch.
const _nativeChannel = MethodChannel('com.ghostcopy.ghostcopy/notifications');

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
    this.openPassphraseRestore = false,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final ISettingsService settingsService;

  /// Go straight to restoring the passphrase on open.
  ///
  /// Set by the "N clips are encrypted" banner, whose own copy says "Tap to
  /// enter your passphrase" - so dropping the user on the settings list and
  /// leaving them to find the control was a promise the screen did not keep.
  final bool openPassphraseRestore;

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

  // Screenshot protection state (Android only - FLAG_SECURE)
  bool _screenshotProtection = true;
  bool _screenshotProtectionLoading = false;

  // URL shortening state
  bool _autoShortenUrls = false;
  Set<String> _defaultDevices = {};
  bool _urlShortenerLoading = false;

  // App info
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _initializeEncryption().then((_) {
      // Chained rather than fired alongside: _restoreFromBackup needs the
      // service _initializeEncryption stands up, and that method already makes
      // its own auto-restore attempt - so if the passphrase came back from the
      // cloud there is nothing left to ask the user for, and opening a dialog
      // on top of a screen that has just silently succeeded would be noise.
      if (!mounted || !widget.openPassphraseRestore) return;
      if (_encryptionEnabled) return;
      unawaited(_restoreFromBackup());
    });
    _loadDevices();
    _loadAppInfo();
    _loadUrlShorteningStatus();
    _loadScreenshotProtection();
    _loadDefaultDevices();
  }

  Future<void> _loadDefaultDevices() async {
    final devices = await locator<ISettingsService>()
        .getAutoSendTargetDevices();
    if (mounted) setState(() => _defaultDevices = devices);
  }

  /// Every destination a clip can be sent to.
  ///
  /// Taken from ClipboardRepository.validDeviceTypes rather than written out
  /// again. A local copy here had already drifted: it omitted linux, so
  /// expanding the all-devices sentinel produced an explicit list without it,
  /// and the first time a user turned off any single destination their Linux
  /// machines silently stopped receiving auto-sends and shares. Reading the
  /// canonical list means a platform added there is covered here too.
  static const _allDeviceTypes = ClipboardRepository.validDeviceTypes;

  Future<void> _toggleDefaultDevice(String deviceType) async {
    final normalized = nextDeviceSelection(
      current: _defaultDevices,
      allDeviceTypes: _allDeviceTypes,
      toggled: deviceType,
    );
    // Null means the toggle would have emptied the set, which reads as "all".
    if (normalized == null) return;

    // Local state first, then persist. Two chips tapped in quick succession
    // both computed from the same _defaultDevices while the first write was
    // still in flight, so each removed only its own device and whichever write
    // landed last discarded the other tap. Updating first means the second tap
    // builds on the first, and it also makes the chip respond immediately
    // rather than after a round trip to storage.
    if (mounted) setState(() => _defaultDevices = normalized);
    await locator<ISettingsService>().setAutoSendTargetDevices(normalized);
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

  Future<void> _loadScreenshotProtection() async {
    final enabled = await widget.settingsService.getScreenshotProtection();
    if (mounted) setState(() => _screenshotProtection = enabled);
  }

  /// Persist the preference and apply it to the window immediately.
  ///
  /// Applied live as well as saved, so the switch means something the moment it
  /// is flipped rather than at next launch - the native side re-reads the same
  /// preference at startup to get the Recents preview right from the first
  /// frame.
  Future<void> _handleScreenshotProtectionChange(bool enabled) async {
    setState(() => _screenshotProtectionLoading = true);
    try {
      await widget.settingsService.setScreenshotProtection(enabled: enabled);
      if (Platform.isAndroid) {
        await _nativeChannel.invokeMethod<bool>('setScreenshotProtection', {
          'enabled': enabled,
        });
      }
      if (!mounted) return;
      setState(() {
        _screenshotProtection = enabled;
        _screenshotProtectionLoading = false;
      });
    } on Exception catch (e) {
      debugPrint('[Settings] Failed to set screenshot protection: $e');
      if (mounted) setState(() => _screenshotProtectionLoading = false);
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
        try {
          await repo.getHistory();
        } on Object catch (e) {
          // getHistory throws RepositoryException on any network or Postgrest
          // error. Unguarded, that escaped this onChanged handler as an
          // unhandled async error and left _encryptionLoading true, disabling
          // the switch for the life of the screen with nothing said about the
          // passphrase just entered.
          debugPrint('[MobileSettings] Passphrase check failed: $e');
          if (!mounted) return;
          setState(() => _encryptionLoading = false);
          showGhostToast(
            context,
            'Could not check your passphrase - try again',
            type: GhostToastType.error,
          );
          return;
        }
        if (!mounted) return;

        final lockedAfter = repo.undecryptableItemCount.value;
        debugPrint(
          '[MobileSettings] Passphrase check: locked $lockedBefore -> '
          '$lockedAfter',
        );

        if (lockedAfter >= lockedBefore) {
          try {
            await _encryptionService!.clearPassphrase();
          } on Object catch (e) {
            debugPrint('[MobileSettings] Failed to clear passphrase: $e');
            if (!mounted) return;
            setState(() => _encryptionLoading = false);
            showGhostToast(
              context,
              'That passphrase did not unlock any clips, and it could not be '
              'cleared - try again',
              type: GhostToastType.error,
            );
            return;
          }
          if (!mounted) return;
          setState(() {
            _encryptionEnabled = false;
            _encryptionLoading = false;
          });
          showGhostToast(
            context,
            'That passphrase did not unlock any of your clips',
            type: GhostToastType.error,
          );
          return;
        }

        setState(() => _encryptionLoading = false);

        if (lockedAfter > 0) {
          // Partial success is the expected outcome after a passphrase change.
          showGhostToast(
            context,
            '${lockedBefore - lockedAfter} clip(s) unlocked. $lockedAfter '
            'still use a different passphrase.',
            type: GhostToastType.success,
          );
          setState(() => _encryptionEnabled = true);
          return;
        }
      }

      setState(() => _encryptionEnabled = true);
      // No toast for the plain "encryption is now on" case - the switch has
      // already moved and says exactly that. Only outcomes the switch CANNOT
      // express still speak up: a passphrase that unlocked nothing, or one that
      // unlocked some clips but not all.
      if (hasExistingEncrypted) {
        showGhostToast(
          context,
          'Passphrase accepted - your clips are unlocked',
          type: GhostToastType.success,
        );
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
        try {
          await _encryptionService!.clearPassphrase();
        } on Object catch (e) {
          // Same stuck-switch failure as the enable path: clearPassphrase()
          // rethrows on a secure-storage error, and unguarded that left
          // _encryptionLoading true, disabling the switch for the life of the
          // screen with nothing said.
          debugPrint('[MobileSettings] Failed to disable encryption: $e');
          if (!mounted) return;
          setState(() => _encryptionLoading = false);
          showGhostToast(
            context,
            'Could not turn encryption off - try again',
            type: GhostToastType.error,
          );
          return;
        }
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
          // No toast. The clips that were unreadable a moment ago are now
          // legible and the encryption row reads as on - the screen has already
          // said it, and a banner over the top is just something else to
          // dismiss.
          setState(() => _encryptionEnabled = true);
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
            }
          }
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _encryptionLoading = false);
        showGhostToast(context, 'Error: $e', type: GhostToastType.error);
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

          showGhostToast(
            context,
            'Device removed',
            type: GhostToastType.success,
          );
        } else {
          showGhostToast(
            context,
            'Failed to remove device',
            type: GhostToastType.error,
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
        // Same colour as the body: see AppTheme.appBarTheme for why.
        backgroundColor: GhostColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 62,
        titleSpacing: GhostSpacing.gutter,
        // Match the main screen: AppBar would otherwise pick its own overlay
        // style from the background colour and re-opaque the status bar.
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
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
      // Same content cap as the main screen, for the same reason: settings is
      // one column of cards, and on a tablet each row would otherwise run the
      // full width with its control stranded far from its label.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: GhostSpacing.maxContentWidth,
          ),
          child: ListView(
            physics: Adaptive.scrollPhysics,
            // Edge-to-edge: keep the last row clear of the gesture bar.
            // The first header lost its top inset along with the others, so the
            // list supplies it here - otherwise "Features" would sit flush against
            // the app bar while every later section had a gap above it.
            padding: EdgeInsets.only(
              top: GhostSpacing.gutter,
              bottom: MediaQuery.viewPaddingOf(context).bottom,
            ),
            scrollCacheExtent: const ScrollCacheExtent.pixels(300),
            children: [
              // Features section (moved to top)
              _buildSectionHeader('Features'),
              _buildFeaturesSection(),

              const SizedBox(height: GhostSpacing.sectionLoose),

              // Devices section
              _buildSectionHeader('Devices'),
              _buildDevicesSection(),

              const SizedBox(height: GhostSpacing.sectionLoose),

              // Security section
              _buildSectionHeader('Security'),
              _buildSecuritySection(),

              const SizedBox(height: GhostSpacing.sectionLoose),

              // Account section (moved to bottom)
              _buildSectionHeader('Account'),
              _buildAccountSection(),

              const SizedBox(height: GhostSpacing.sectionLoose),

              // About section
              _buildSectionHeader('About'),
              _buildAboutSection(),

              const SizedBox(height: GhostSpacing.sectionLoose),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      // No top padding: every header already sits below a sectionLoose gap, and
      // adding a gutter on top of it made the real distance between sections
      // 25 + 16 = 41px - wider than anything on the home screen and, because
      // the first header has no gap above it, inconsistent with itself too.
      // The single sectionLoose owns the spacing between sections; the 8 below
      // is the header's own relationship to the card it labels.
      padding: const EdgeInsets.fromLTRB(
        GhostSpacing.gutter,
        0,
        GhostSpacing.gutter,
        8,
      ),
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
      margin: const EdgeInsets.symmetric(horizontal: GhostSpacing.gutter),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
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

          const Divider(height: 1, color: GhostColors.border),

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
      margin: const EdgeInsets.symmetric(horizontal: GhostSpacing.gutter),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
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
              // THIS is the dead space under the last device, not anything in
              // the row itself.
              //
              // BoxScrollView.build() treats a null padding on a vertical list
              // as "pad me with MediaQuery.padding" - which on a gesture-nav
              // device means the bottom system inset gets injected INSIDE this
              // card. The list is shrinkWrap'd and non-scrolling, nested in a
              // page that already handles its own insets, so it should claim
              // none of that.
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _devices.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, color: GhostColors.border),
              itemBuilder: (context, index) {
                final device = _devices[index];
                final isCurrent =
                    device.id == widget.deviceService.getCurrentDeviceId();

                // An explicit Row, not a ListTile.
                //
                // ListTile derives its own height from Material's two-line
                // minimum and from whichever of content/leading/trailing is
                // tallest, and a row carrying a delete button ended up both
                // taller than the "This device" row and bottom-heavy, so the
                // card looked like it had dead space under the last device.
                // That geometry is implicit and awkward to reason about; this
                // states the height rule outright and both rows now measure
                // the same whether or not they have a trailing button.
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: GhostSpacing.gutter,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        iconForDeviceType(device.deviceType),
                        color: GhostColors.primary,
                        size: 20,
                      ),
                      const SizedBox(width: GhostSpacing.gutter),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    device.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: GhostColors.textPrimary,
                                    ),
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
                                      color: GhostColors.success.withValues(
                                        alpha: 0.2,
                                      ),
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
                            const SizedBox(height: 2),
                            Text(
                              platformLabel(device.deviceType),
                              style: const TextStyle(
                                fontSize: 12,
                                color: GhostColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Sized to the text beside it rather than to a 48dp touch
                      // box, so the delete button cannot set the row height.
                      // Still 40dp of tappable area via the SizedBox.
                      if (!isCurrent)
                        SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              color: Colors.red.shade400,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            // The actual culprit behind the dead space under the
                            // last device. IconButton defaults to
                            // MaterialTapTargetSize.padded, which reserves a
                            // 48dp box and survives both the SizedBox above and
                            // the cleared constraints - so only the row WITH a
                            // delete button was inflated, and only that row sat
                            // bottom-heavy. shrinkWrap lets the 40dp box hold.
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => _handleRemoveDevice(
                              device.id,
                              device.displayName,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
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
      }
    } on Exception catch (e) {
      debugPrint('Failed to update URL shortening setting: $e');
      if (mounted) {
        setState(() => _urlShortenerLoading = false);
        showGhostToast(
          context,
          'Failed to update setting',
          type: GhostToastType.error,
        );
      }
    }
  }

  Widget _buildFeaturesSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: GhostSpacing.gutter),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
      ),
      child: Column(
        children: [
          // URL shortening toggle
          _settingSwitch(
            icon: Icons.link,
            title: 'Auto-Shorten URLs',
            subtitle: 'Automatically shorten long URLs before sending',
            value: _autoShortenUrls,
            onChanged: _urlShortenerLoading ? null : _handleUrlShorteningToggle,
          ),
          const Divider(height: 1, color: GhostColors.border),
          _buildDefaultDevicesTile(),
        ],
      ),
    );
  }

  /// Where a share from another app goes.
  ///
  /// Sharing into GhostCopy sends straight here without asking, so this has to
  /// be visible and editable on mobile - otherwise the target is set on the
  /// desktop and invisible on the phone doing the sending.
  Widget _buildDefaultDevicesTile() {
    const deviceTypes = _allDeviceTypes;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices, color: GhostColors.primary, size: 20),
              const SizedBox(width: 16),
              const Text(
                'Default devices',
                style: TextStyle(fontSize: 14, color: GhostColors.textPrimary),
              ),
              const SizedBox(width: 8),
              // Expanded rather than a Spacer with a loose Text. The summary
              // grows with the selection - the first toggle away from "All
              // devices" already leaves three names - and an unconstrained
              // Text after a Spacer has no room to give back, so on a 320pt
              // phone the icon, gap, title and summary together overran the
              // tile and the row overflowed. Taking the remaining width and
              // ellipsising keeps the count legible at any width.
              Expanded(
                child: Text(
                  _defaultDevices.isEmpty
                      ? 'All devices'
                      : _defaultDevices.map(platformLabel).join(', '),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: GhostColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.only(left: 36),
            child: Text(
              'Where shared files and auto-send go.',
              style: TextStyle(fontSize: 12, color: GhostColors.textMuted),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in deviceTypes)
                  _DefaultDeviceChip(
                    label: platformLabel(type),
                    icon: iconForDeviceType(type),
                    isSelected:
                        _defaultDevices.isEmpty ||
                        _defaultDevices.contains(type),
                    onTap: () => _toggleDefaultDevice(type),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The switch itself, native to the platform.
  ///
  /// Switch.adaptive, not Switch: on iOS that is a CupertinoSwitch, which is
  /// what the row used before these three toggles were unified and what an iOS
  /// user expects to see. A Material switch on iOS reads as a port.
  ///
  /// activeTrackColor is set here rather than left to AppTheme.switchTheme
  /// because CupertinoSwitch does not read Material's SwitchTheme - without it
  /// iOS would fall back to the system green while Android showed the accent.
  /// One place, both platforms, unlike the per-call-site overrides this
  /// replaced.
  ///
  /// Only Android is scaled down. Material 3's switch is 52x32 and overweight
  /// beside 14px type; CupertinoSwitch is already the size iOS users know, and
  /// shrinking it would make it the odd one out on its own platform.

  /// One switch row, so every toggle in Settings is the same size and colour.
  ///
  /// They had drifted: two set activeTrackColor to the success green while the
  /// third used the accent, so the Security section showed two different "on"
  /// colours side by side. Colour now comes from AppTheme.switchTheme alone.
  ///
  /// Scaled down because Material 3's switch is 52x32 - next to 14px type in a
  /// list it reads as the heaviest thing on the screen.
  Widget _settingSwitch({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: GhostColors.primary, size: 20),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, color: GhostColors.textPrimary),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: GhostColors.textMuted),
      ),
      trailing: AdaptiveSwitch(value: value, onChanged: onChanged),
      // The whole row toggles, which SwitchListTile gave for free.
      onTap: onChanged == null ? null : () => onChanged(!value),
    );
  }

  Widget _buildSecuritySection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: GhostSpacing.gutter),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
      ),
      child: Column(
        children: [
          // Android only: iOS has no FLAG_SECURE equivalent, so showing the
          // switch there would promise protection the platform cannot give.
          if (Platform.isAndroid) ...[
            _settingSwitch(
              icon: Icons.screenshot_outlined,
              title: 'Block Screenshots',
              subtitle:
                  'Also hides clips in the app switcher and screen shares',
              value: _screenshotProtection,
              onChanged: _screenshotProtectionLoading
                  ? null
                  : _handleScreenshotProtectionChange,
            ),
            const Divider(height: 1, color: GhostColors.border),
          ],
          // Encryption toggle
          _settingSwitch(
            icon: Icons.lock_outline,
            title: 'End-to-End Encryption',
            subtitle: 'Encrypt clipboard items with a passphrase',
            value: _encryptionEnabled,
            onChanged: _encryptionLoading ? null : _handleEncryptionToggle,
          ),

          // Explicit "Restore" button if has backup but currently disabled
          if (!_encryptionEnabled && _hasBackup) ...[
            const Divider(height: 1, color: GhostColors.border),
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
        ],
      ),
    );
  }

  /// Ask first, then hand off to the browser.
  ///
  /// Both stores treat silently throwing the user into a browser as a dark
  /// pattern, and reviewers look for it. Naming the destination and requiring a
  /// tap means leaving the app is always the user's decision, and the URL is
  /// visible before they commit rather than after.
  Future<void> _openWebsite() async {
    final confirmed = await Adaptive.confirm(
      context,
      title: 'Open the GhostCopy website?',
      message: 'This opens $_websiteUrl in your browser, outside GhostCopy.',
      confirmText: 'Open',
    );

    if (!confirmed || !mounted) return;

    final opened = await launchUrl(
      Uri.parse(_websiteUrl),
      mode: LaunchMode.externalApplication,
    );

    if (!opened && mounted) {
      showGhostToast(
        context,
        'Could not open the browser',
        type: GhostToastType.error,
      );
    }
  }

  Widget _buildAboutSection() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: GhostSpacing.gutter),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
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
        // Signals that the row does something now. It used to be inert, which
        // left About looking like a dead end.
        trailing: const Icon(
          Icons.open_in_new_rounded,
          size: 18,
          color: GhostColors.textMuted,
        ),
        onTap: _openWebsite,
      ),
    );
  }
}

/// One platform chip in the Default devices row.
class _DefaultDeviceChip extends StatelessWidget {
  const _DefaultDeviceChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      // Explicit on both branches: a null hover colour falls back to the
      // theme's white overlay, which flashes on these dark surfaces.
      hoverColor: isSelected
          ? GhostColors.primaryHover
          : GhostColors.surfaceLight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? GhostColors.primaryAlpha20 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? GhostColors.primary : GhostColors.surfaceLight,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? GhostColors.primary : GhostColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected
                    ? GhostColors.textPrimary
                    : GhostColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
