import 'package:flutter/foundation.dart';

/// Represents a hotkey configuration
class HotKey {
  const HotKey({
    required this.key,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  /// Parse a hotkey from [toStorageString]. Returns null if malformed.
  ///
  /// Unknown modifier tokens are ignored rather than treated as the key, so a
  /// value written by a future version cannot silently register the wrong
  /// shortcut.
  static HotKey? fromStorageString(String? value) {
    if (value == null || value.isEmpty) return null;

    final parts = value.toLowerCase().split('+');
    if (parts.isEmpty) return null;

    final key = parts.last.trim();
    if (key.isEmpty) return null;

    final modifiers = parts.take(parts.length - 1).map((p) => p.trim()).toSet();
    const known = {'ctrl', 'shift', 'alt', 'meta'};
    if (!modifiers.every(known.contains)) return null;

    return HotKey(
      key: key,
      ctrl: modifiers.contains('ctrl'),
      shift: modifiers.contains('shift'),
      alt: modifiers.contains('alt'),
      meta: modifiers.contains('meta'),
    );
  }

  final String key;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  /// Stable textual form, e.g. `ctrl+shift+s`.
  ///
  /// Also used as the identity of a registration, so the modifier order here
  /// is fixed and must not depend on iteration order.
  String toStorageString() {
    final parts = <String>[
      if (ctrl) 'ctrl',
      if (shift) 'shift',
      if (alt) 'alt',
      if (meta) 'meta',
      key.toLowerCase(),
    ];
    return parts.join('+');
  }

  // Value equality: HotKey is used as a map key and compared across rebuilds,
  // where two structurally identical instances must be the same hotkey.
  @override
  bool operator ==(Object other) =>
      other is HotKey &&
      other.key.toLowerCase() == key.toLowerCase() &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key.toLowerCase(), ctrl, shift, alt, meta);

  @override
  String toString() => 'HotKey(${toStorageString()})';
}

/// Abstract interface for global hotkey management
abstract class IHotkeyService {
  /// Register a global hotkey with a callback
  ///
  /// Throws [UnsupportedHotkeyException] if [hotkey] names a key this platform
  /// cannot register, leaving any previous registration untouched.
  Future<void> registerHotkey(HotKey hotkey, VoidCallback callback);

  /// Unregister a previously registered hotkey
  Future<void> unregisterHotkey(HotKey hotkey);

  /// Dispose of the service and clean up resources
  Future<void> dispose();
}

/// Thrown when a hotkey names a key that cannot be mapped to a physical key.
///
/// Previously an unknown key silently fell back to `S`, so choosing Ctrl+Shift+K
/// registered Ctrl+Shift+S and the UI reported a shortcut that did not exist.
class UnsupportedHotkeyException implements Exception {
  UnsupportedHotkeyException(this.key);

  final String key;

  @override
  String toString() => 'UnsupportedHotkeyException: unsupported key "$key"';
}
