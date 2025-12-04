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

  final String key;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;
}

/// Abstract interface for global hotkey management
abstract class IHotkeyService {
  /// Register a global hotkey with a callback
  Future<void> registerHotkey(HotKey hotkey, VoidCallback callback);

  /// Unregister a previously registered hotkey
  Future<void> unregisterHotkey(HotKey hotkey);

  /// Dispose of the service and clean up resources
  void dispose();
}
