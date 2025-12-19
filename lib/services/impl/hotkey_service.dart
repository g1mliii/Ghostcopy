import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart' as hkm;
import '../hotkey_service.dart';

/// Concrete implementation of IHotkeyService using hotkey_manager package
///
/// Manages global keyboard shortcuts for desktop platforms.
/// Maintains hotkey listener even in Sleep Mode (Requirement 3.4).
class HotkeyService implements IHotkeyService {
  final Map<String, hkm.HotKey> _registeredHotkeys = {};

  /// Register a global hotkey with a callback
  ///
  /// Requirement 1.1: Display Spotlight window within 200ms of hotkey press
  /// Requirement 3.4: Maintain hotkey listener active in Sleep Mode
  @override
  Future<void> registerHotkey(HotKey hotkey, VoidCallback callback) async {
    // Only register hotkeys on desktop platforms
    if (!_isDesktop()) {
      return;
    }

    // Convert our HotKey model to hotkey_manager's HotKey
    final hkmHotkey = hkm.HotKey(
      key: _convertKey(hotkey.key),
      modifiers: _buildModifiers(hotkey),
    );

    // Generate a unique key for this hotkey configuration
    final hotkeyKey = _generateHotkeyKey(hotkey);

    // Unregister if already exists
    if (_registeredHotkeys.containsKey(hotkeyKey)) {
      await hkm.hotKeyManager.unregister(_registeredHotkeys[hotkeyKey]!);
    }

    // Register the hotkey
    await hkm.hotKeyManager.register(
      hkmHotkey,
      keyDownHandler: (hotKey) {
        // Execute callback immediately for 200ms requirement
        callback();
      },
    );

    _registeredHotkeys[hotkeyKey] = hkmHotkey;
  }

  /// Unregister a previously registered hotkey
  @override
  Future<void> unregisterHotkey(HotKey hotkey) async {
    if (!_isDesktop()) {
      return;
    }

    final hotkeyKey = _generateHotkeyKey(hotkey);
    final hkmHotkey = _registeredHotkeys[hotkeyKey];

    if (hkmHotkey != null) {
      await hkm.hotKeyManager.unregister(hkmHotkey);
      _registeredHotkeys.remove(hotkeyKey);
    }
  }

  /// Dispose of the service and clean up resources
  @override
  Future<void> dispose() async {
    // Unregister all hotkeys and await completion. Wrap in try/catch to
    // avoid throwing during app shutdown which could crash the host.
    try {
      await Future.wait(
        _registeredHotkeys.values.map(hkm.hotKeyManager.unregister),
      );
    } on Object catch (e, st) {
      // Log and continue shutdown
      debugPrint('HotkeyService.dispose error: $e\n$st');
    }

    _registeredHotkeys.clear();
  }

  /// Convert our key string to PhysicalKeyboardKey
  PhysicalKeyboardKey _convertKey(String key) {
    // Map common keys to PhysicalKeyboardKey
    switch (key.toLowerCase()) {
      case 's':
        return PhysicalKeyboardKey.keyS;
      case 'c':
        return PhysicalKeyboardKey.keyC;
      case 'v':
        return PhysicalKeyboardKey.keyV;
      case 'a':
        return PhysicalKeyboardKey.keyA;
      case 'space':
        return PhysicalKeyboardKey.space;
      case 'escape':
        return PhysicalKeyboardKey.escape;
      case 'enter':
        return PhysicalKeyboardKey.enter;
      default:
        // Default to keyS if unknown
        return PhysicalKeyboardKey.keyS;
    }
  }

  /// Build modifier list from HotKey configuration
  List<hkm.HotKeyModifier> _buildModifiers(HotKey hotkey) {
    final modifiers = <hkm.HotKeyModifier>[];

    if (hotkey.ctrl) {
      modifiers.add(hkm.HotKeyModifier.control);
    }
    if (hotkey.shift) {
      modifiers.add(hkm.HotKeyModifier.shift);
    }
    if (hotkey.alt) {
      modifiers.add(hkm.HotKeyModifier.alt);
    }
    if (hotkey.meta) {
      modifiers.add(hkm.HotKeyModifier.meta);
    }

    return modifiers;
  }

  /// Generate a unique key for a HotKey configuration
  String _generateHotkeyKey(HotKey hotkey) {
    final parts = <String>[];
    if (hotkey.ctrl) parts.add('ctrl');
    if (hotkey.shift) parts.add('shift');
    if (hotkey.alt) parts.add('alt');
    if (hotkey.meta) parts.add('meta');
    parts.add(hotkey.key);
    return parts.join('+');
  }

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
