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
  const DevicePanel({
    required this.deviceService,
    super.key,
  });

  final IDeviceService deviceService;

  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> {
  List<Device>? _cachedDevices;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices({bool forceRefresh = false}) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final devices = await widget.deviceService.getUserDevices(
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _cachedDevices = devices;
          _isLoading = false;
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load devices: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<bool> _handleRename(String deviceId, String newName) async {
    final success = await widget.deviceService.updateDeviceName(deviceId, newName);
    if (success) {
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
    if (success) {
      // Remove from local cache
      setState(() {
        _cachedDevices = _cachedDevices?.where((d) => d.id != deviceId).toList();
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
              Text(
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
                  onPressed: () => _loadDevices(forceRefresh: true),
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
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
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
                  Icon(
                    Icons.error_outline,
                    size: 18,
                    color: Colors.red[300],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
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
              child: Row(
                children: [
                  Icon(
                    Icons.devices_other,
                    size: 18,
                    color: GhostColors.textMuted,
                  ),
                  const SizedBox(width: 8),
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
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _cachedDevices!.length,
              itemBuilder: (context, index) {
                final device = _cachedDevices![index];
                final currentDeviceId = widget.deviceService.getCurrentDeviceId();
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: GhostColors.primary,
                  ),
                  const SizedBox(width: 6),
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
