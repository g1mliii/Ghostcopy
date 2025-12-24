import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings_service.dart';

/// Concrete implementation of ISettingsService using shared_preferences
///
/// Manages user preferences for GhostCopy app:
/// - Auto-send feature toggle (monitor clipboard and auto-sync)
/// - Clipboard staleness duration (for smart auto-receive)
class SettingsService implements ISettingsService {
  SharedPreferences? _prefs;
  bool _initialized = false;

  // Settings keys
  static const String _keyAutoSendEnabled = 'auto_send_enabled';
  static const String _keyStaleDurationMinutes = 'clipboard_stale_duration_minutes';
  static const String _keyAutoSendTargetDevices = 'auto_send_target_devices';
  static const String _keyAutoStartEnabled = 'auto_start_enabled';

  // Default values
  static const bool _defaultAutoSendEnabled = false;
  static const int _defaultStaleDurationMinutes = 5;
  static const Set<String> _defaultAutoSendTargetDevices = {}; // Empty = all devices
  static const bool _defaultAutoStartEnabled = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
      debugPrint('SettingsService initialized');
    } on Exception catch (e) {
      debugPrint('Failed to initialize SettingsService: $e');
      rethrow;
    }
  }

  void _ensureInitialized() {
    if (!_initialized || _prefs == null) {
      throw StateError('SettingsService not initialized. Call initialize() first.');
    }
  }

  @override
  Future<bool> getAutoSendEnabled() async {
    _ensureInitialized();
    return _prefs!.getBool(_keyAutoSendEnabled) ?? _defaultAutoSendEnabled;
  }

  @override
  Future<void> setAutoSendEnabled({required bool enabled}) async {
    _ensureInitialized();
    await _prefs!.setBool(_keyAutoSendEnabled, enabled);
    debugPrint('Auto-send ${enabled ? "enabled" : "disabled"}');
  }

  @override
  Future<int> getClipboardStaleDurationMinutes() async {
    _ensureInitialized();
    return _prefs!.getInt(_keyStaleDurationMinutes) ?? _defaultStaleDurationMinutes;
  }

  @override
  Future<void> setClipboardStaleDurationMinutes(int minutes) async {
    _ensureInitialized();

    // Validate range (1-60 minutes)
    if (minutes < 1 || minutes > 60) {
      throw ArgumentError('Stale duration must be between 1-60 minutes');
    }

    await _prefs!.setInt(_keyStaleDurationMinutes, minutes);
    debugPrint('Clipboard stale duration set to $minutes minutes');
  }

  @override
  Future<Set<String>> getAutoSendTargetDevices() async {
    _ensureInitialized();
    final devices = _prefs!.getStringList(_keyAutoSendTargetDevices);
    if (devices == null || devices.isEmpty) {
      return _defaultAutoSendTargetDevices;
    }
    return devices.toSet();
  }

  @override
  Future<void> setAutoSendTargetDevices(Set<String> devices) async {
    _ensureInitialized();

    // Validate device types
    const validDevices = {'windows', 'macos', 'android', 'ios'};
    final invalidDevices = devices.where((d) => !validDevices.contains(d));
    if (invalidDevices.isNotEmpty) {
      throw ArgumentError('Invalid device types: ${invalidDevices.join(", ")}');
    }

    await _prefs!.setStringList(_keyAutoSendTargetDevices, devices.toList());
    debugPrint(
      'Auto-send target devices: ${devices.isEmpty ? "all devices" : devices.join(", ")}',
    );
  }

  @override
  Future<bool> getAutoStartEnabled() async {
    _ensureInitialized();
    return _prefs!.getBool(_keyAutoStartEnabled) ?? _defaultAutoStartEnabled;
  }

  @override
  Future<void> setAutoStartEnabled({required bool enabled}) async {
    _ensureInitialized();
    await _prefs!.setBool(_keyAutoStartEnabled, enabled);
    debugPrint('Auto-start ${enabled ? "enabled" : "disabled"}');
  }

  @override
  void dispose() {
    _prefs = null;
    _initialized = false;
  }
}
