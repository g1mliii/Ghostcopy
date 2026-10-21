import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/device_service.dart';
import '../theme/colors.dart';
import 'device_list_item.dart';

/// Device management panel for viewing and managing registered devices
///
/// Optimized for performance:
/// - Cached device list with manual refresh
/// - RepaintBoundary to isolate repaints
/// - Minimal rebuilds via stateful management
class DevicePanel extends StatefulWidget {
  const DevicePanel({required this.deviceService, super.key});

  final IDeviceService deviceService;

  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  List<Device>? _cachedDevices;

  /// Whether the spinner shows: a fetch is out and there is nothing to show
  /// in the meantime.
  bool _isLoading = false;

  /// Whether a fetch is out at all. Separate from [_isLoading], which goes
  /// false as soon as a saved list is drawn - guarding on that let a refresh
  /// tapped meanwhile start a second fetch, and the slower of the two won.
  bool _fetching = false;

  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  /// Fetch the devices, drawing the list the last launch saved while that
  /// runs on first open, rather than a spinner. See SavedDeviceList.
  ///
  /// fetchUserDevices, not getUserDevices: that reports a failure as [], the
  /// same as an account with no devices. Here a failure must leave a saved
  /// list in place and a real empty answer must replace it.
  Future<void> _loadDevices() async {
    if (_fetching) return;
    _fetching = true;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    if (_cachedDevices == null) unawaited(_showSavedDevices());

    List<Device>? devices;
    try {
      devices = await widget.deviceService.fetchUserDevices();
    } on Exception catch (e) {
      debugPrint('[DevicePanel] Failed to load devices: $e');
    } finally {
      _fetching = false;
    }
    if (!mounted) return;
    setState(() {
      if (devices != null) {
        _cachedDevices = devices;
      } else if (_cachedDevices == null) {
        _error = 'Failed to load devices. Check your connection.';
      }
      _isLoading = false;
    });
  }

  Future<void> _showSavedDevices() async {
    final saved = await widget.deviceService.getSavedDevices();
    // Only while the fetch is still out: a list it already returned is newer.
    if (!mounted || !_fetching || _cachedDevices != null || saved.isEmpty) {
      return;
    }
    setState(() {
      _cachedDevices = saved;
      _isLoading = false;
    });
  }

  Future<bool> _handleRename(String deviceId, String newName) async {
    final success = await widget.deviceService.updateDeviceName(
      deviceId,
      newName,
    );
    // mounted, not just success: the panel can be closed while the rename is
    // in flight, and setState after dispose throws.
    if (success && mounted) {
      // Update local cache to reflect name change
      setState(() {
        _cachedDevices = _cachedDevices?.map((device) {
          if (device.id == deviceId) {
            return device.copyWith(deviceName: newName);
          }
          return device;
        }).toList();
      });
    }
    return success;
  }

  Future<bool> _handleRemove(String deviceId) async {
    final success = await widget.deviceService.removeDevice(deviceId);
    if (success && mounted) {
      // Remove from local cache
      setState(() {
        _cachedDevices = _cachedDevices
            ?.where((d) => d.id != deviceId)
            .toList();
      });
    }
    return success;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with refresh button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'YOUR DEVICES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: GhostColors.textMuted,
                  letterSpacing: 0.5,
                ),
              ),
              if (!_isLoading)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  color: GhostColors.textMuted,
                  onPressed: _loadDevices,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  tooltip: 'Refresh devices',
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Device list or loading/error state
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(
                  color: GhostColors.primary,
                  strokeWidth: 2,
                ),
              ),
            )
          else if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GhostColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: Colors.red[300]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: GhostColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (_cachedDevices == null || _cachedDevices!.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: GhostColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.devices_other,
                    size: 18,
                    color: GhostColors.textMuted,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No devices registered yet',
                      style: TextStyle(
                        fontSize: 12,
                        color: GhostColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            // Device list
            ListView.builder(
              // A null padding on a vertical list makes BoxScrollView inject
              // MediaQuery.padding, so this nested, non-scrolling list would
              // claim the window's system insets as its own bottom padding.
              // Same bug that put dead space under the last device on mobile.
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _cachedDevices!.length,
              itemBuilder: (context, index) {
                final device = _cachedDevices![index];
                final currentDeviceId = widget.deviceService
                    .getCurrentDeviceId();
                final isCurrentDevice = device.id == currentDeviceId;

                return RepaintBoundary(
                  key: ValueKey(device.id),
                  child: DeviceListItem(
                    device: device,
                    isCurrentDevice: isCurrentDevice,
                    onRename: _handleRename,
                    onRemove: _handleRemove,
                  ),
                );
              },
            ),
          // Info text
          if (_cachedDevices != null && _cachedDevices!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: GhostColors.surface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: GhostColors.primary,
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Tap device name to rename (current device only). Remove inactive devices to keep your list clean.',
                      style: TextStyle(
                        fontSize: 10,
                        color: GhostColors.textMuted,
                        height: 1.4,
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
}
