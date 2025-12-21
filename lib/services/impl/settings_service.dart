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

  // Default values
  static const bool _defaultAutoSendEnabled = false;
  static const int _defaultStaleDurationMinutes = 5;

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
  void dispose() {
    _prefs = null;
    _initialized = false;
  }
}
