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

    // Refuse rather than substitute. An unmappable key used to become `S`,
    // which registered a shortcut the user never chose and desynchronised the
    // registration map from what the OS actually holds.
    final physicalKey = convertKey(hotkey.key);
    if (physicalKey == null) {
      throw UnsupportedHotkeyException(hotkey.key);
    }

    // Convert our HotKey model to hotkey_manager's HotKey
    final hkmHotkey = hkm.HotKey(
      key: physicalKey,
      modifiers: _buildModifiers(hotkey),
    );

    // Identity is the hotkey itself, so a re-register of the same combo
    // replaces the existing OS registration instead of stacking a second one.
    final hotkeyKey = _generateHotkeyKey(hotkey);

    // Unregister if already exists
    final existing = _registeredHotkeys.remove(hotkeyKey);
    if (existing != null) {
      await hkm.hotKeyManager.unregister(existing);
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

  /// Physical key for a configured key string, or null if unmappable.
  ///
  /// This used to `switch` over seven keys and return `keyS` for everything
  /// else, while the capture field accepts any single character - so choosing
  /// Ctrl+Shift+K registered Ctrl+Shift+S and the settings UI displayed a
  /// shortcut that was never registered. Callers must treat null as "refuse
  /// this hotkey" rather than substituting a default.
  static PhysicalKeyboardKey? convertKey(String key) {
    final normalized = key.toLowerCase().trim();

    const letters = <String, PhysicalKeyboardKey>{
      'a': PhysicalKeyboardKey.keyA,
      'b': PhysicalKeyboardKey.keyB,
      'c': PhysicalKeyboardKey.keyC,
      'd': PhysicalKeyboardKey.keyD,
      'e': PhysicalKeyboardKey.keyE,
      'f': PhysicalKeyboardKey.keyF,
      'g': PhysicalKeyboardKey.keyG,
      'h': PhysicalKeyboardKey.keyH,
      'i': PhysicalKeyboardKey.keyI,
      'j': PhysicalKeyboardKey.keyJ,
      'k': PhysicalKeyboardKey.keyK,
      'l': PhysicalKeyboardKey.keyL,
      'm': PhysicalKeyboardKey.keyM,
      'n': PhysicalKeyboardKey.keyN,
      'o': PhysicalKeyboardKey.keyO,
      'p': PhysicalKeyboardKey.keyP,
      'q': PhysicalKeyboardKey.keyQ,
      'r': PhysicalKeyboardKey.keyR,
      's': PhysicalKeyboardKey.keyS,
      't': PhysicalKeyboardKey.keyT,
      'u': PhysicalKeyboardKey.keyU,
      'v': PhysicalKeyboardKey.keyV,
      'w': PhysicalKeyboardKey.keyW,
      'x': PhysicalKeyboardKey.keyX,
      'y': PhysicalKeyboardKey.keyY,
      'z': PhysicalKeyboardKey.keyZ,
    };

    const digits = <String, PhysicalKeyboardKey>{
      '0': PhysicalKeyboardKey.digit0,
      '1': PhysicalKeyboardKey.digit1,
      '2': PhysicalKeyboardKey.digit2,
      '3': PhysicalKeyboardKey.digit3,
      '4': PhysicalKeyboardKey.digit4,
      '5': PhysicalKeyboardKey.digit5,
      '6': PhysicalKeyboardKey.digit6,
      '7': PhysicalKeyboardKey.digit7,
      '8': PhysicalKeyboardKey.digit8,
      '9': PhysicalKeyboardKey.digit9,
    };

    const named = <String, PhysicalKeyboardKey>{
      'space': PhysicalKeyboardKey.space,
      'escape': PhysicalKeyboardKey.escape,
      'enter': PhysicalKeyboardKey.enter,
      'tab': PhysicalKeyboardKey.tab,
      'backspace': PhysicalKeyboardKey.backspace,
      'delete': PhysicalKeyboardKey.delete,
      'insert': PhysicalKeyboardKey.insert,
      'home': PhysicalKeyboardKey.home,
      'end': PhysicalKeyboardKey.end,
      'pageup': PhysicalKeyboardKey.pageUp,
      'pagedown': PhysicalKeyboardKey.pageDown,
      'arrowup': PhysicalKeyboardKey.arrowUp,
      'arrowdown': PhysicalKeyboardKey.arrowDown,
      'arrowleft': PhysicalKeyboardKey.arrowLeft,
      'arrowright': PhysicalKeyboardKey.arrowRight,
      'f1': PhysicalKeyboardKey.f1,
      'f2': PhysicalKeyboardKey.f2,
      'f3': PhysicalKeyboardKey.f3,
      'f4': PhysicalKeyboardKey.f4,
      'f5': PhysicalKeyboardKey.f5,
      'f6': PhysicalKeyboardKey.f6,
      'f7': PhysicalKeyboardKey.f7,
      'f8': PhysicalKeyboardKey.f8,
      'f9': PhysicalKeyboardKey.f9,
      'f10': PhysicalKeyboardKey.f10,
      'f11': PhysicalKeyboardKey.f11,
      'f12': PhysicalKeyboardKey.f12,
      'minus': PhysicalKeyboardKey.minus,
      'equal': PhysicalKeyboardKey.equal,
      'bracketleft': PhysicalKeyboardKey.bracketLeft,
      'bracketright': PhysicalKeyboardKey.bracketRight,
      'backslash': PhysicalKeyboardKey.backslash,
      'semicolon': PhysicalKeyboardKey.semicolon,
      'quote': PhysicalKeyboardKey.quote,
      'backquote': PhysicalKeyboardKey.backquote,
      'comma': PhysicalKeyboardKey.comma,
      'period': PhysicalKeyboardKey.period,
      'slash': PhysicalKeyboardKey.slash,
    };

    return letters[normalized] ?? digits[normalized] ?? named[normalized];
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

  /// Identity of a registration - the canonical text form of the hotkey.
  String _generateHotkeyKey(HotKey hotkey) => hotkey.toStorageString();

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
