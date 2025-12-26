import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/hotkey_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Widget for capturing keyboard shortcuts
///
/// Displays current hotkey and allows user to record a new one by pressing keys.
/// Memory-safe: No subscriptions or listeners that need disposal.
class HotkeyCapture extends StatefulWidget {
  const HotkeyCapture({
    required this.currentHotkey,
    required this.onHotkeyChanged,
    super.key,
  });

  final HotKey currentHotkey;
  final ValueChanged<HotKey> onHotkeyChanged;

  @override
  State<HotkeyCapture> createState() => _HotkeyCapture();
}

class _HotkeyCapture extends State<HotkeyCapture> {
  bool _isRecording = false;
  HotKey? _capturedHotkey;

  // Track currently pressed modifier keys
  bool _ctrlPressed = false;
  bool _shiftPressed = false;
  bool _altPressed = false;
  bool _metaPressed = false;

  @override
  Widget build(BuildContext context) {
    final displayHotkey = _capturedHotkey ?? widget.currentHotkey;
    final hotkeyText = _formatHotkey(displayHotkey);

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
                Icons.keyboard,
                size: 14,
                color: GhostColors.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Global Hotkey',
                style: GhostTypography.body.copyWith(
                  fontSize: 13,
                  color: GhostColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isRecording
                ? 'Press a key combination...'
                : 'Current: $hotkeyText',
            style: GhostTypography.caption.copyWith(
              color: _isRecording
                  ? GhostColors.primary
                  : GhostColors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Hotkey display / capture area
              Expanded(
                child: _isRecording
                    ? _buildRecordingArea()
                    : _buildHotkeyDisplay(hotkeyText),
              ),
              const SizedBox(width: 8),
              // Record / Cancel button
              ElevatedButton(
                onPressed: _toggleRecording,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRecording
                      ? GhostColors.surface
                      : GhostColors.primary,
                  foregroundColor: _isRecording
                      ? GhostColors.textPrimary
                      : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: Text(
                  _isRecording ? 'Cancel' : 'Change',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHotkeyDisplay(String hotkeyText) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: GhostColors.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: GhostColors.surfaceLight),
      ),
      child: Text(
        hotkeyText,
        style: GhostTypography.body.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: GhostColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildRecordingArea() {
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: GhostColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: GhostColors.primary, width: 2),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: GhostColors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Listening...',
              style: GhostTypography.body.copyWith(
                fontSize: 13,
                color: GhostColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleRecording() {
    setState(() {
      _isRecording = !_isRecording;
      if (!_isRecording) {
        // User canceled
        _capturedHotkey = null;
        _resetModifiers();
      }
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isRecording) return KeyEventResult.ignored;

    // Track modifier keys
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
          event.logicalKey == LogicalKeyboardKey.controlRight) {
        _ctrlPressed = true;
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
          event.logicalKey == LogicalKeyboardKey.shiftRight) {
        _shiftPressed = true;
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.altLeft ||
          event.logicalKey == LogicalKeyboardKey.altRight) {
        _altPressed = true;
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.metaLeft ||
          event.logicalKey == LogicalKeyboardKey.metaRight) {
        _metaPressed = true;
        return KeyEventResult.handled;
      }

      // Capture letter/number keys
      final keyLabel = event.logicalKey.keyLabel.toLowerCase();
      if (keyLabel.length == 1 && (_ctrlPressed || _shiftPressed || _altPressed || _metaPressed)) {
        // Valid hotkey captured
        final newHotkey = HotKey(
          key: keyLabel,
          ctrl: _ctrlPressed,
          shift: _shiftPressed,
          alt: _altPressed,
          meta: _metaPressed,
        );

        setState(() {
          _capturedHotkey = newHotkey;
          _isRecording = false;
        });

        _resetModifiers();
        widget.onHotkeyChanged(newHotkey);

        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.handled;
  }

  void _resetModifiers() {
    _ctrlPressed = false;
    _shiftPressed = false;
    _altPressed = false;
    _metaPressed = false;
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
