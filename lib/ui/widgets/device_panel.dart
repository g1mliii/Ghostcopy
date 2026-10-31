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

  /// Renames and removals that have succeeded while this panel is open, as
  /// changes to a device list. A fetch that started before one finished
  /// answers with the list from before it; the edits made since are applied
  /// to that answer rather than lost under it.
  final _edits = <List<Device> Function(List<Device> devices)>[];

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  /// Fetch the devices, drawing the list the last launch saved while that
  /// runs on first open, rather than a spinner. See fetchDevicesShowingSaved.
  Future<void> _loadDevices() async {
    if (_fetching) return;
    _fetching = true;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final editsBefore = _edits.length;
    var devices = await fetchDevicesShowingSaved(
      widget.deviceService,
      onSaved: (saved) {
        if (!mounted || _cachedDevices != null) return;
        setState(() {
          _cachedDevices = saved;
          _isLoading = false;
        });
      },
    );
    // The saved list is drawn and usable while the fetch is out, so a rename
    // or removal can finish before it answers. The server accepted it, so the
    // answer plus the edit is the server's list now - and keeps whatever else
    // the answer brought, which asking again could lose to a failed request.
    for (final edit in _edits.skip(editsBefore)) {
      if (devices != null) devices = edit(devices);
    }
    _fetching = false;
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

  Future<bool> _handleRename(String deviceId, String newName) async {
    final success = await widget.deviceService.updateDeviceName(
      deviceId,
      newName,
    );
    if (success) {
      _applyEdit(
        (devices) => [
          for (final device in devices)
            device.id == deviceId
                ? device.copyWith(deviceName: newName)
                : device,
        ],
      );
    }
    return success;
  }

  Future<bool> _handleRemove(String deviceId) async {
    final success = await widget.deviceService.removeDevice(deviceId);
    if (success) {
      _applyEdit(
        (devices) => [
          for (final device in devices)
            if (device.id != deviceId) device,
        ],
      );
    }
    return success;
  }

  /// Draws a rename or removal the server has accepted, and keeps it for a
  /// fetch still out to apply to its answer.
  void _applyEdit(List<Device> Function(List<Device> devices) edit) {
    _edits.add(edit);
    // The panel can be closed while the request is in flight, and setState
    // after dispose throws.
    if (!mounted) return;
    final devices = _cachedDevices;
    if (devices != null) setState(() => _cachedDevices = edit(devices));
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
