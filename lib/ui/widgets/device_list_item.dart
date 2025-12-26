import 'package:flutter/material.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../models/device.dart';
import '../theme/colors.dart';

/// A single device item in the device list
///
/// Optimized for performance with:
/// - RepaintBoundary to isolate repaints
/// - Const constructors where possible
/// - Minimal rebuilds via callbacks
class DeviceListItem extends StatefulWidget {
  const DeviceListItem({
    required this.device,
    required this.isCurrentDevice,
    required this.onRename,
    required this.onRemove,
    super.key,
  });

  final Device device;
  final bool isCurrentDevice;
  final Future<bool> Function(String deviceId, String newName) onRename;
  final Future<bool> Function(String deviceId) onRemove;

  @override
  State<DeviceListItem> createState() => _DeviceListItemState();
}

class _DeviceListItemState extends State<DeviceListItem> {
  bool _isEditing = false;
  late TextEditingController _nameController;
  bool _isRemoving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.device.displayName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  IconData _getDeviceIcon() {
    switch (widget.device.deviceType) {
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  String _getRelativeTime() {
    final now = DateTime.now();
    final diff = now.difference(widget.device.lastActive);

    if (diff.inMinutes < 2) {
      return 'Active now';
    }

    return timeago.format(widget.device.lastActive, locale: 'en_short');
  }

  bool _isInactive() {
    final diff = DateTime.now().difference(widget.device.lastActive);
    return diff.inDays >= 7;
  }

  Future<void> _saveName() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty || newName == widget.device.displayName) {
      setState(() => _isEditing = false);
      return;
    }

    final success = await widget.onRename(widget.device.id, newName);
    if (success && mounted) {
      setState(() => _isEditing = false);
    }
  }

  Future<void> _confirmRemove() async {
    final shouldRemove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GhostColors.surface,
        title: Text(
          'Remove Device?',
          style: TextStyle(color: GhostColors.textPrimary),
        ),
        content: Text(
          'Remove "${widget.device.displayName}" from your devices?',
          style: TextStyle(color: GhostColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: GhostColors.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (shouldRemove ?? false) {
      setState(() => _isRemoving = true);
      final success = await widget.onRemove(widget.device.id);
      if (mounted && !success) {
        setState(() => _isRemoving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRemoving) {
      return const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: widget.isCurrentDevice
              ? Border.all(color: GhostColors.primary.withValues(alpha: 0.3))
              : null,
        ),
        child: Row(
          children: [
            // Device icon
            Icon(
              _getDeviceIcon(),
              size: 24,
              color: widget.isCurrentDevice
                  ? GhostColors.primary
                  : _isInactive()
                      ? GhostColors.textMuted
                      : GhostColors.textSecondary,
            ),
            const SizedBox(width: 12),
            // Device info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Device name (editable)
                  Row(
                    children: [
                      Expanded(
                        child: _isEditing
                            ? TextField(
                                controller: _nameController,
                                autofocus: true,
                                maxLength: 255,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: GhostColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(4),
                                    borderSide: BorderSide(
                                      color: GhostColors.primary,
                                    ),
                                  ),
                                  counterText: '',
                                ),
                                onSubmitted: (_) => _saveName(),
                              )
                            : GestureDetector(
                                onTap: widget.isCurrentDevice
                                    ? () => setState(() => _isEditing = true)
                                    : null,
                                child: Row(
                                  children: [
                                    Text(
                                      widget.device.displayName,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: GhostColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (widget.isCurrentDevice) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: GhostColors.primary
                                              .withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'This device',
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: GhostColors.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Device type and last active
                  Row(
                    children: [
                      Text(
                        widget.device.deviceType[0].toUpperCase() +
                            widget.device.deviceType.substring(1),
                        style: TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      Text(
                        ' · ',
                        style: TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      Text(
                        _getRelativeTime(),
                        style: TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Status indicator
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isInactive()
                              ? GhostColors.textMuted.withValues(alpha: 0.3)
                              : GhostColors.success,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Edit/Remove buttons
            if (_isEditing) ...[
              IconButton(
                icon: const Icon(Icons.check, size: 18),
                color: GhostColors.success,
                onPressed: _saveName,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: GhostColors.textMuted,
                onPressed: () => setState(() {
                  _isEditing = false;
                  _nameController.text = widget.device.displayName;
                }),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ] else if (!widget.isCurrentDevice) ...[
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                color: GhostColors.textMuted,
                onPressed: _confirmRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
