import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/settings_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

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
    required this.onClose,
    required this.onOpenAuth,
    required this.onAutoSendChanged,
    required this.onStaleDurationChanged,
    super.key,
  });

  final IAuthService authService;
  final ISettingsService settingsService;
  final bool autoSendEnabled;
  final int staleDurationMinutes;
  final VoidCallback onClose;
  final VoidCallback onOpenAuth;
  final ValueChanged<bool> onAutoSendChanged;
  final ValueChanged<int> onStaleDurationChanged;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  Set<String> _autoSendTargetDevices = {};

  @override
  void initState() {
    super.initState();
    _loadTargetDevices();
  }

  Future<void> _loadTargetDevices() async {
    final devices = await widget.settingsService.getAutoSendTargetDevices();
    if (mounted) {
      setState(() => _autoSendTargetDevices = devices);
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
      setState(() => _autoSendTargetDevices = newDevices);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
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
        const SizedBox(height: 16),
        // Auto-send target devices (only show if auto-send is enabled)
        if (widget.autoSendEnabled) ...[
          _buildDeviceSelector(),
          const SizedBox(height: 20),
        ],
        // Stale duration slider
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
        const SizedBox(height: 20),
        // Info text
        _buildInfoCard(),
        const SizedBox(height: 32),
        // Account Section
        Text(
          'ACCOUNT',
          style: GhostTypography.caption.copyWith(
            color: GhostColors.textMuted,
          ),
        ),
        const SizedBox(height: 12),
        // Account status button
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
    return Container(
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
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
    return Container(
      padding: const EdgeInsets.all(12),
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
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(12),
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
                Icons.info_outline,
                size: 14,
                color: GhostColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Smart Auto-Receive',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: GhostColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "New clips from other devices auto-paste only if your clipboard hasn't changed recently.",
            style: TextStyle(
              fontSize: 11,
              color: GhostColors.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountButton() {
    return InkWell(
      onTap: widget.onOpenAuth,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(12),
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
      padding: const EdgeInsets.all(12),
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
            _autoSendTargetDevices.isEmpty
                ? 'All devices'
                : _autoSendTargetDevices.map((d) {
                    final device = devices.firstWhere((item) => item.$1 == d);
                    return device.$3;
                  }).join(', '),
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
            style: TextStyle(
              fontSize: 10,
              color: GhostColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
