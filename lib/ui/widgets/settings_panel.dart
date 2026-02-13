import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/auto_start_service.dart';
import '../../services/device_service.dart';
import '../../services/encryption_service.dart';
import '../../services/hotkey_service.dart';
import '../../services/settings_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'device_panel.dart';
import 'hotkey_capture_field.dart';
import 'link_device_dialog.dart';
import 'passphrase_dialog.dart';

/// Settings panel for app configuration and account access
///
/// Extracted from SpotlightScreen to reduce widget complexity.
/// Displays settings toggles/sliders and provides access to auth panel.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    required this.authService,
    required this.settingsService,
    required this.autoSendEnabled,
    required this.staleDurationMinutes,
    required this.autoReceiveBehavior,
    required this.onClose,
    required this.onOpenAuth,
    required this.onAutoSendChanged,
    required this.onStaleDurationChanged,
    required this.onAutoReceiveBehaviorChanged,

    this.onEncryptionChanged,
    this.autoStartService,
    this.hotkeyService,
    this.deviceService,
    this.encryptionService,
    super.key,
  });

  final IAuthService authService;
  final ISettingsService settingsService;
  final IAutoStartService? autoStartService;
  final IHotkeyService? hotkeyService;
  final IDeviceService? deviceService;
  final IEncryptionService? encryptionService;
  final bool autoSendEnabled;
  final int staleDurationMinutes;
  final AutoReceiveBehavior autoReceiveBehavior;
  final VoidCallback onClose;
  final VoidCallback onOpenAuth;
  final ValueChanged<bool> onAutoSendChanged;
  final ValueChanged<int> onStaleDurationChanged;
  final ValueChanged<AutoReceiveBehavior> onAutoReceiveBehaviorChanged;
  final VoidCallback? onEncryptionChanged;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  Set<String> _autoSendTargetDevices = {};
  bool _autoStartEnabled = false;
  bool _encryptionEnabled = false;
  bool _hasBackup = false;
  bool _autoShortenUrls = false;
  bool _webhookEnabled = false;
  String _webhookUrl = '';
  bool _obsidianEnabled = false;
  String _obsidianVaultPath = '';
  String _obsidianFileName = 'clipboard.md';
  HotKey _currentHotkey = const HotKey(key: 's', ctrl: true, shift: true);

  // Text controllers
  final _webhookUrlController = TextEditingController();
  final _obsidianVaultPathController = TextEditingController();
  final _obsidianFileNameController = TextEditingController();

  // Cache expensive computations
  String? _cachedDeviceText;

  // Separate debounce timers per field to prevent data loss
  Timer? _webhookDebounceTimer;
  Timer? _vaultPathDebounceTimer;
  Timer? _fileNameDebounceTimer;

  @override
  void initState() {
    super.initState();
    // Load async data immediately without waiting
    _loadTargetDevices();
    _loadAutoStartSetting();
    _loadEncryptionStatus();
    _loadUrlShorteningStatus();
    _loadWebhookStatus();
    _loadObsidianStatus();
  }

  @override
  void dispose() {
    // Flush any pending writes before disposing (fire-and-forget safe pattern)
    // Note: We intentionally don't await to prevent blocking dispose
    // Settings are persisted to SharedPreferences which is synchronous internally
    _flushPendingWrites();

    // Cancel all timers
    _webhookDebounceTimer?.cancel();
    _vaultPathDebounceTimer?.cancel();
    _fileNameDebounceTimer?.cancel();

    // Dispose controllers
    _webhookUrlController.dispose();
    _obsidianVaultPathController.dispose();
    _obsidianFileNameController.dispose();
    super.dispose();
  }

  /// Flush all pending debounced writes immediately (fire-and-forget)
  ///
  /// Safe to call in dispose() because:
  /// 1. SharedPreferences writes are synchronous internally (cached in memory)
  /// 2. These are "best effort" persists - if they fail, user can re-enter
  /// 3. Blocking dispose() with await would be worse (janky UI, delayed cleanup)
  void _flushPendingWrites() {
    // Execute any pending webhook write
    if (_webhookDebounceTimer?.isActive ?? false) {
      _webhookDebounceTimer?.cancel();
      // Fire-and-forget: SharedPreferences caches writes synchronously
      widget.settingsService.setWebhookUrl(_webhookUrlController.text);
    }

    // Execute any pending vault path write
    if (_vaultPathDebounceTimer?.isActive ?? false) {
      _vaultPathDebounceTimer?.cancel();
      widget.settingsService.setObsidianVaultPath(_obsidianVaultPathController.text);
    }

    // Execute any pending file name write
    if (_fileNameDebounceTimer?.isActive ?? false) {
      _fileNameDebounceTimer?.cancel();
      widget.settingsService.setObsidianFileName(_obsidianFileNameController.text);
    }
  }

  Future<void> _loadTargetDevices() async {
    final devices = await widget.settingsService.getAutoSendTargetDevices();
    if (mounted) {
      setState(() {
        _autoSendTargetDevices = devices;
        _cachedDeviceText = null; // Reset cache
      });
    }
  }

  Future<void> _loadAutoStartSetting() async {
    if (widget.autoStartService == null) return;

    final enabled = await widget.settingsService.getAutoStartEnabled();
    if (mounted) {
      setState(() => _autoStartEnabled = enabled);
    }
  }

  Future<void> _loadEncryptionStatus() async {
    if (widget.encryptionService == null) return;

    var enabled = await widget.encryptionService!.isEnabled();

    // Check for backup if encryption is disabled
    var hasBackup = false;

    if (!enabled && widget.authService.currentUser != null) {
      // Ensure service is initialized with user ID
      await widget.encryptionService!.initialize(widget.authService.currentUser!.id);

      hasBackup = await widget.encryptionService!.hasCloudBackup();

      // If we have a backup, try to auto-restore immediately (user convenience)
      if (hasBackup) {
        debugPrint('[SettingsPanel] Backup found, attempting auto-restore on load...');
        try {
          final restored = await widget.encryptionService!.autoRestoreFromCloud();
          if (restored) {
             // If restored successfully, we are now enabled!
             enabled = true;
             // Notify parent to refresh history
             widget.onEncryptionChanged?.call();
          }
        } on Exception catch (e) {
          debugPrint('[SettingsPanel] Auto-restore on load failed: $e');
          // Silent failure on load - let user click Restore button to retry/manual
        }
      }
    }

    if (mounted) {
      setState(() {
        _encryptionEnabled = enabled;
        _hasBackup = hasBackup;
      });
    }
  }

  Future<void> _loadUrlShorteningStatus() async {
    final enabled = await widget.settingsService.getAutoShortenUrls();
    if (mounted) {
      setState(() => _autoShortenUrls = enabled);
    }
  }

  Future<void> _loadWebhookStatus() async {
    final enabled = await widget.settingsService.getWebhookEnabled();
    final url = await widget.settingsService.getWebhookUrl();
    if (mounted) {
      setState(() {
        _webhookEnabled = enabled;
        _webhookUrl = url ?? '';
        _webhookUrlController.text = _webhookUrl;
      });
    }
  }

  Future<void> _loadObsidianStatus() async {
    final enabled = await widget.settingsService.getObsidianEnabled();
    final vaultPath = await widget.settingsService.getObsidianVaultPath();
    final fileName = await widget.settingsService.getObsidianFileName();
    if (mounted) {
      setState(() {
        _obsidianEnabled = enabled;
        _obsidianVaultPath = vaultPath ?? '';
        _obsidianFileName = fileName;
        _obsidianVaultPathController.text = _obsidianVaultPath;
        _obsidianFileNameController.text = _obsidianFileName;
      });
    }
  }

  Future<void> _toggleEncryption() async {
    if (widget.encryptionService == null) return;

    if (_encryptionEnabled) {
      // Disable encryption - show confirmation dialog
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Disable Encryption?'),
          content: const Text(
            'This will disable encryption for new clipboard items. '
            'Existing encrypted items will remain encrypted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Disable'),
            ),
          ],
        ),
      );

      if (confirmed ?? false) {
        await widget.encryptionService!.clearPassphrase();
        if (mounted) {
          setState(() => _encryptionEnabled = false);
          widget.onEncryptionChanged?.call();
        }
      }
    } else {
      // Enable encryption - show passphrase dialog
      // Get current user ID
      final userId = widget.authService.currentUserId;
      if (userId == null) {
        // User not authenticated - should not happen
        debugPrint('[SettingsPanel] Cannot enable encryption: user not authenticated');
        return;
      }

      final success = await showPassphraseDialog(
        context,
        widget.encryptionService!,
        userId,
      );

      if (success && mounted) {
        setState(() => _encryptionEnabled = true);
        widget.onEncryptionChanged?.call();
      }
    }
  }

  Future<void> _restoreFromBackup() async {
    if (widget.encryptionService == null) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      // 1. Attempt auto-restore from cloud
      final success = await widget.encryptionService!.autoRestoreFromCloud();
      
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        
        if (success) {
          setState(() {
            _encryptionEnabled = true;
            _hasBackup = true; 
          });
          
          widget.onEncryptionChanged?.call();

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Encryption passphrase restored!')),
          );
        } else {
          // 2. Fallback to manual entry if restore fails
          if (mounted) {
            unawaited(_showManualRestoreDialog());
          }
        }
      }
    } on Exception catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        // Fallback to manual entry on error too
        unawaited(_showManualRestoreDialog());
        debugPrint('Auto-restore failed: $e');
      }
    }
  }

  Future<void> _showManualRestoreDialog() async {
    final userId = widget.authService.currentUserId;
    if (userId == null) return;

    // We reuse the set passphrase dialog but change the title/intent conceptually
    // In this app reuse context, setting the passphrase again IS restoring it manually
    // because it derives the same key if the passphrase is the same.
    final success = await showPassphraseDialog(
      context,
      widget.encryptionService!,
      userId,
      isRestoreMode: true,
    );

    if (success && mounted) {
      setState(() => _encryptionEnabled = true);
      widget.onEncryptionChanged?.call();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrase set manually. History decrypted.')),
      );
    }
  }

  Future<void> _toggleDevice(String deviceType) async {
    final newDevices = Set<String>.from(_autoSendTargetDevices);
    if (newDevices.contains(deviceType)) {
      newDevices.remove(deviceType);
    } else {
      newDevices.add(deviceType);
    }

    await widget.settingsService.setAutoSendTargetDevices(newDevices);
    if (mounted) {
      setState(() {
        _autoSendTargetDevices = newDevices;
        _cachedDeviceText = null; // Reset cache
      });
    }
  }

  /// Cache expensive string operation
  String _getDeviceText(List<(String, IconData, String)> devices) {
    if (_cachedDeviceText != null) return _cachedDeviceText!;

    _cachedDeviceText = _autoSendTargetDevices.isEmpty
        ? 'All devices'
        : _autoSendTargetDevices.map((d) {
            final device = devices.firstWhere((item) => item.$1 == d);
            return device.$3;
          }).join(', ');

    return _cachedDeviceText!;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    // NOTE: Individual builder methods (_buildSettingToggle, _buildTextField, etc.)
    // already wrap their content in RepaintBoundary. No need for additional wrapping here.
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // 1. Most Important: Feature Toggles
        // Auto-send toggle
        _buildSettingToggle(
          title: 'Auto-send clipboard',
          subtitle: 'Automatically sync when you copy',
          value: widget.autoSendEnabled,
          onChanged: (value) async {
            await widget.settingsService.setAutoSendEnabled(enabled: value);
            widget.onAutoSendChanged(value);
          },
        ),
        const SizedBox(height: 10),
        // Auto-send target devices (only show if auto-send is enabled)
        if (widget.autoSendEnabled) ...[
          _buildDeviceSelector(),
          const SizedBox(height: 10),
        ],
        // URL shortening toggle
        _buildSettingToggle(
          title: 'Auto-shorten URLs',
          subtitle: 'Automatically shorten long URLs before sending',
          value: _autoShortenUrls,
          onChanged: (value) async {
            await widget.settingsService.setAutoShortenUrls(enabled: value);
            if (mounted) {
              setState(() => _autoShortenUrls = value);
            }
          },
        ),
        const SizedBox(height: 10),
        // Webhook toggle & settings
        Column(
          children: [
            _buildSettingToggle(
              title: 'Webhook Integration',
              subtitle: 'Send clipboard data to external services',
              value: _webhookEnabled,
              onChanged: (value) async {
                await widget.settingsService.setWebhookEnabled(enabled: value);
                if (mounted) {
                  setState(() => _webhookEnabled = value);
                }
              },
            ),
            if (_webhookEnabled) ...[
              const SizedBox(height: 10),
              _buildTextField(
                label: 'Webhook URL',
                controller: _webhookUrlController,
                onChanged: (value) async {
                  await widget.settingsService.setWebhookUrl(value);
                },
                getTimer: () => _webhookDebounceTimer,
                setTimer: (timer) => _webhookDebounceTimer = timer,
              ),
            ],
          ],
        ),
        const SizedBox(height: 10),
        // Obsidian toggle & settings
        Column(
          children: [
            _buildSettingToggle(
              title: 'Obsidian Integration',
              subtitle: 'Auto-append to Obsidian vault',
              value: _obsidianEnabled,
              onChanged: (value) async {
                await widget.settingsService.setObsidianEnabled(enabled: value);
                if (mounted) {
                  setState(() => _obsidianEnabled = value);
                }
              },
            ),
            if (_obsidianEnabled) ...[
              const SizedBox(height: 10),
              _buildTextField(
                label: 'Vault Path',
                controller: _obsidianVaultPathController,
                onChanged: (value) async {
                  await widget.settingsService.setObsidianVaultPath(value);
                },
                getTimer: () => _vaultPathDebounceTimer,
                setTimer: (timer) => _vaultPathDebounceTimer = timer,
              ),
              const SizedBox(height: 10),
              _buildTextField(
                label: 'File Name',
                controller: _obsidianFileNameController,
                onChanged: (value) async {
                  await widget.settingsService.setObsidianFileName(value);
                },
                getTimer: () => _fileNameDebounceTimer,
                setTimer: (timer) => _fileNameDebounceTimer = timer,
              ),
            ],
          ],
        ),

        const SizedBox(height: 20),
        const Divider(height: 1, color: GhostColors.glassBorder),
        const SizedBox(height: 20),

        // 2. Configuration & Behavior
        // Stale duration slider (only show if in smart mode)
        if (widget.autoReceiveBehavior == AutoReceiveBehavior.smart) ...[
          _buildSettingSlider(
            title: 'Clipboard staleness',
            subtitle: 'Auto-paste after ${widget.staleDurationMinutes} min',
            value: widget.staleDurationMinutes.toDouble(),
            min: 1,
            max: 60,
            divisions: 59,
            onChanged: widget.onStaleDurationChanged,
            onChangeEnd: (value) async {
              await widget.settingsService.setClipboardStaleDurationMinutes(value);
            },
          ),
          const SizedBox(height: 10),
        ],
        // Auto-receive behavior selector
        _buildAutoReceiveBehaviorSelector(),
        const SizedBox(height: 12),
        // Info text
        _buildInfoCard(),
        const SizedBox(height: 20),

        // 3. Device Management
        if (widget.deviceService != null) ...[
          DevicePanel(deviceService: widget.deviceService!),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: const Text('Link New Device'),
              style: FilledButton.styleFrom(
                backgroundColor: GhostColors.primary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () => showLinkDeviceDialog(
                context,
                widget.authService,
                widget.encryptionService!,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],

        const Divider(height: 1, color: GhostColors.glassBorder),
        const SizedBox(height: 20),

        // 4. Set and Forget (System Settings)
        if (isDesktop) ...[
           Text(
            'SYSTEM',
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
           if (widget.autoStartService != null) ...[
            _buildSettingToggle(
              title: 'Launch at startup',
              subtitle: 'Start GhostCopy when you log in',
              value: _autoStartEnabled,
              onChanged: (value) async {
                if (value) {
                  await widget.autoStartService!.enable();
                } else {
                  await widget.autoStartService!.disable();
                }
                await widget.settingsService.setAutoStartEnabled(enabled: value);
                if (mounted) {
                  setState(() => _autoStartEnabled = value);
                }
              },
            ),
            const SizedBox(height: 10),
          ],
          if (widget.hotkeyService != null) ...[
            HotkeyCapture(
              currentHotkey: _currentHotkey,
              onHotkeyChanged: (newHotkey) async {
                await widget.hotkeyService!.unregisterHotkey(_currentHotkey);
                if (mounted) {
                  setState(() => _currentHotkey = newHotkey);
                }
                debugPrint('Hotkey changed to: ${_formatHotkey(newHotkey)}');
              },
            ),
            const SizedBox(height: 20),
          ],
        ],

        // 5. Security
        if (widget.encryptionService != null) ...[
          Text(
            'SECURITY',
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          _buildEncryptionSection(),
          const SizedBox(height: 20),
        ],

        // 6. Account
        Text(
          'ACCOUNT',
          style: GhostTypography.caption.copyWith(
            color: GhostColors.textMuted,
          ),
        ),
        const SizedBox(height: 12),
        _buildAccountButton(),
      ],
    );
  }

  Widget _buildSettingToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SwitchListTile(
          title: Text(
            title,
            style: GhostTypography.body.copyWith(
              fontSize: 13,
              color: GhostColors.textPrimary,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
          value: value,
          onChanged: onChanged,
          activeTrackColor: GhostColors.primary,
          thumbColor: WidgetStateProperty.all(GhostColors.primary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    required Timer? Function() getTimer,
    required void Function(Timer?) setTimer,
  }) {
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: TextField(
          controller: controller,
          style: GhostTypography.body.copyWith(
            fontSize: 12,
            color: GhostColors.textPrimary,
          ),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (value) {
            // Use field-specific timer to prevent data loss
            getTimer()?.cancel();
            setTimer(
              Timer(
                const Duration(milliseconds: 500),
                () => onChanged(value),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSettingSlider({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<int> onChanged,
    required ValueChanged<int> onChangeEnd,
  }) {
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GhostTypography.body.copyWith(
              fontSize: 13,
              color: GhostColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: GhostColors.primary,
            inactiveColor: GhostColors.surface,
            onChanged: (val) => onChanged(val.toInt()),
            onChangeEnd: (val) => onChangeEnd(val.toInt()),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildAutoReceiveBehaviorSelector() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.download,
                size: 14,
                color: GhostColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Auto-receive from other devices',
                style: GhostTypography.body.copyWith(
                  fontSize: 13,
                  color: GhostColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...AutoReceiveBehavior.values.map((behavior) => _AutoReceiveBehaviorOption(
            behavior: behavior,
            isSelected: widget.autoReceiveBehavior == behavior,
            onTap: () async {
              await widget.settingsService.setAutoReceiveBehavior(behavior);
              widget.onAutoReceiveBehaviorChanged(behavior);
            },
          )),
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: GhostColors.primary,
                ),
                SizedBox(width: 6),
                Text(
                  'About Auto-Receive',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: GhostColors.textPrimary,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              'Smart mode auto-copies when your clipboard is idle. Never mode shows a clickable notification instead.',
              style: TextStyle(
                fontSize: 11,
                color: GhostColors.textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountButton() {
    return RepaintBoundary(
      child: InkWell(
        onTap: widget.onOpenAuth,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: GhostColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
          children: [
            Icon(
              widget.authService.isAnonymous ? Icons.person_outline : Icons.verified_user,
              size: 18,
              color: GhostColors.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.authService.isAnonymous
                        ? 'Anonymous User'
                        : widget.authService.currentUser?.email ?? '',
                    style: GhostTypography.body.copyWith(
                      fontSize: 13,
                      color: GhostColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.authService.isAnonymous
                        ? 'Tap to upgrade account'
                        : 'Manage account',
                    style: GhostTypography.caption.copyWith(
                      color: GhostColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 16,
              color: GhostColors.textMuted,
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildDeviceSelector() {
    const devices = [
      ('windows', Icons.desktop_windows, 'Windows'),
      ('macos', Icons.laptop_mac, 'macOS'),
      ('android', Icons.phone_android, 'Android'),
      ('ios', Icons.phone_iphone, 'iOS'),
    ];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.devices,
                size: 14,
                color: GhostColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Send to devices',
                style: GhostTypography.body.copyWith(
                  fontSize: 13,
                  color: GhostColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _getDeviceText(devices),
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          // Device checkboxes
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: devices.map((device) {
              final (type, icon, label) = device;
              final isSelected = _autoSendTargetDevices.isEmpty ||
                  _autoSendTargetDevices.contains(type);

              return InkWell(
                onTap: () => _toggleDevice(type),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? GhostColors.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isSelected
                          ? GhostColors.primary
                          : GhostColors.surfaceLight,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 14,
                        color: isSelected
                            ? GhostColors.primary
                            : GhostColors.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: isSelected
                              ? GhostColors.primary
                              : GhostColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap to select specific devices or leave all selected',
            style: const TextStyle(
              fontSize: 10,
              color: GhostColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEncryptionSection() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _encryptionEnabled ? Icons.lock : Icons.lock_open,
                size: 18,
                color: _encryptionEnabled ? GhostColors.success : GhostColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'End-to-End Encryption',
                      style: GhostTypography.body.copyWith(
                        fontSize: 13,
                        color: GhostColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _encryptionEnabled
                          ? 'Clipboard encrypted with your passphrase'
                          : _hasBackup
                              ? 'Backup found - restore to decrypt items'
                              : 'Protect clipboard with passphrase',
                      style: GhostTypography.caption.copyWith(
                        color: GhostColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_encryptionEnabled && _hasBackup)
                FilledButton(
                  onPressed: _restoreFromBackup,
                  style: FilledButton.styleFrom(
                    backgroundColor: GhostColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  child: const Text(
                    'Restore',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              else
                FilledButton(
                  onPressed: _toggleEncryption,
                  style: FilledButton.styleFrom(
                    backgroundColor: _encryptionEnabled
                        ? GhostColors.textMuted
                        : GhostColors.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: Size.zero,
                  ),
                  child: Text(
                    _encryptionEnabled ? 'Disable' : 'Enable',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          if (!_encryptionEnabled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: GhostColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: GhostColors.primary.withValues(alpha: 0.3),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: GhostColors.primary),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Passphrase stored securely in system keychain',
                      style: TextStyle(
                        fontSize: 11,
                        color: GhostColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatHotkey(HotKey hotkey) {
    final parts = <String>[];
    if (hotkey.ctrl) parts.add('Ctrl');
    if (hotkey.shift) parts.add('Shift');
    if (hotkey.alt) parts.add('Alt');
    if (hotkey.meta) parts.add('Meta');
    parts.add(hotkey.key.toUpperCase());
    return parts.join(' + ');
  }
}

/// Auto-receive behavior radio button option
class _AutoReceiveBehaviorOption extends StatelessWidget {
  const _AutoReceiveBehaviorOption({
    required this.behavior,
    required this.isSelected,
    required this.onTap,
  });

  final AutoReceiveBehavior behavior;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? GhostColors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected ? GhostColors.primary : GhostColors.surface,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: isSelected ? GhostColors.primary : GhostColors.textMuted,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  behavior.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected
                        ? GhostColors.textPrimary
                        : GhostColors.textSecondary,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
