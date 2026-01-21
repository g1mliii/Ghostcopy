import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  static const String _keyAutoReceiveBehavior = 'auto_receive_behavior';
  static const String _keyClipboardAutoClearSeconds = 'clipboard_auto_clear_seconds';
  static const String _keyAutoShortenUrls = 'auto_shorten_urls';
  static const String _keyWebhookEnabled = 'webhook_enabled';
  static const String _keyWebhookUrl = 'webhook_url';
  static const String _keyObsidianEnabled = 'obsidian_enabled';
  static const String _keyObsidianVaultPath = 'obsidian_vault_path';
  static const String _keyObsidianFileName = 'obsidian_file_name';

  // Default values
  static const bool _defaultAutoSendEnabled = false;
  static const int _defaultStaleDurationMinutes = 5;
  static const Set<String> _defaultAutoSendTargetDevices = {}; // Empty = all devices
  static const bool _defaultAutoStartEnabled = false;
  static const AutoReceiveBehavior _defaultAutoReceiveBehavior = AutoReceiveBehavior.smart;
  static const int _defaultClipboardAutoClearSeconds = 30; // 30 seconds default
  static const bool _defaultAutoShortenUrls = false;
  static const bool _defaultWebhookEnabled = false;
  static const bool _defaultObsidianEnabled = false;
  static const String _defaultObsidianFileName = 'clipboard.md';

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
  Future<AutoReceiveBehavior> getAutoReceiveBehavior() async {
    _ensureInitialized();
    final value = _prefs!.getString(_keyAutoReceiveBehavior);
    if (value == null) return _defaultAutoReceiveBehavior;

    // Parse enum from stored string
    return AutoReceiveBehavior.values.firstWhere(
      (e) => e.name == value,
      orElse: () => _defaultAutoReceiveBehavior,
    );
  }

  @override
  Future<void> setAutoReceiveBehavior(AutoReceiveBehavior behavior) async {
    _ensureInitialized();
    await _prefs!.setString(_keyAutoReceiveBehavior, behavior.name);
    debugPrint('Auto-receive behavior set to: ${behavior.label}');
  }

  @override
  Future<int> getClipboardAutoClearSeconds() async {
    _ensureInitialized();
    return _prefs!.getInt(_keyClipboardAutoClearSeconds) ?? _defaultClipboardAutoClearSeconds;
  }

  @override
  Future<void> setClipboardAutoClearSeconds(int seconds) async {
    _ensureInitialized();

    // Validate range (0-300 seconds, where 0 = disabled)
    if (seconds < 0 || seconds > 300) {
      throw ArgumentError('Auto-clear duration must be between 0-300 seconds');
    }

    await _prefs!.setInt(_keyClipboardAutoClearSeconds, seconds);
    if (seconds == 0) {
      debugPrint('Clipboard auto-clear disabled');
    } else {
      debugPrint('Clipboard auto-clear set to $seconds seconds');
    }
  }

  // ========== FEATURE TOGGLES ==========

  @override
  Future<bool> getAutoShortenUrls() async {
    _ensureInitialized();
    return _prefs!.getBool(_keyAutoShortenUrls) ?? _defaultAutoShortenUrls;
  }

  @override
  Future<void> setAutoShortenUrls({required bool enabled}) async {
    _ensureInitialized();
    await _prefs!.setBool(_keyAutoShortenUrls, enabled);
    debugPrint('Auto-shorten URLs ${enabled ? "enabled" : "disabled"}');
  }

  @override
  Future<bool> getWebhookEnabled() async {
    _ensureInitialized();
    return _prefs!.getBool(_keyWebhookEnabled) ?? _defaultWebhookEnabled;
  }

  @override
  Future<void> setWebhookEnabled({required bool enabled}) async {
    _ensureInitialized();
    await _prefs!.setBool(_keyWebhookEnabled, enabled);
    debugPrint('Webhook ${enabled ? "enabled" : "disabled"}');
  }

  @override
  Future<String?> getWebhookUrl() async {
    _ensureInitialized();
    return _prefs!.getString(_keyWebhookUrl);
  }

  @override
  Future<void> setWebhookUrl(String? url) async {
    _ensureInitialized();
    if (url == null || url.isEmpty) {
      await _prefs!.remove(_keyWebhookUrl);
      debugPrint('Webhook URL cleared');
    } else {
      await _prefs!.setString(_keyWebhookUrl, url);
      debugPrint('Webhook URL set');
    }
  }

  @override
  Future<bool> getObsidianEnabled() async {
    _ensureInitialized();
    return _prefs!.getBool(_keyObsidianEnabled) ?? _defaultObsidianEnabled;
  }

  @override
  Future<void> setObsidianEnabled({required bool enabled}) async {
    _ensureInitialized();
    await _prefs!.setBool(_keyObsidianEnabled, enabled);
    debugPrint('Obsidian ${enabled ? "enabled" : "disabled"}');
  }

  @override
  Future<String?> getObsidianVaultPath() async {
    _ensureInitialized();
    return _prefs!.getString(_keyObsidianVaultPath);
  }

  @override
  Future<void> setObsidianVaultPath(String? path) async {
    _ensureInitialized();
    if (path == null || path.isEmpty) {
      await _prefs!.remove(_keyObsidianVaultPath);
      debugPrint('Obsidian vault path cleared');
    } else {
      await _prefs!.setString(_keyObsidianVaultPath, path);
      debugPrint('Obsidian vault path set');
    }
  }

  @override
  Future<String> getObsidianFileName() async {
    _ensureInitialized();
    return _prefs!.getString(_keyObsidianFileName) ?? _defaultObsidianFileName;
  }

  @override
  Future<void> setObsidianFileName(String fileName) async {
    _ensureInitialized();
    await _prefs!.setString(_keyObsidianFileName, fileName);
    debugPrint('Obsidian file name set to: $fileName');
  }

  // ========== FEATURE FLAGS ==========

  /// Check if hybrid mode is enabled (from Supabase app_config table)
  @override
  Future<bool> isHybridModeEnabled() async {
    try {
      final config = await Supabase.instance.client
          .from('app_config')
          .select('enabled')
          .eq('key', 'hybrid_mode_enabled')
          .maybeSingle();

      final isEnabled = config?['enabled'] as bool? ?? false;

      debugPrint(
        '[Settings] 🎛️  Hybrid mode: ${isEnabled ? "ENABLED" : "DISABLED"}',
      );

      return isEnabled;
    } on Exception catch (e) {
      debugPrint('[Settings] ⚠️  Failed to check hybrid mode flag: $e');
      return false; // Default to disabled if error
    }
  }

  @override
  void dispose() {
    _prefs = null;
    _initialized = false;
  }
}
