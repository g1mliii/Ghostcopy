export 'impl/settings_service.dart';

/// Auto-receive behavior options for incoming clipboard items
enum AutoReceiveBehavior {
  /// Always auto-copy to clipboard regardless of staleness
  always('Always auto-copy'),

  /// Smart: Only auto-copy if clipboard is stale (default)
  smart('Smart (when clipboard is stale)'),

  /// Never auto-copy, only show notification
  never('Never auto-copy');

  const AutoReceiveBehavior(this.label);
  final String label;
}

/// Abstract interface for app settings management
abstract class ISettingsService {
  /// Get auto-send enabled setting (default: false)
  Future<bool> getAutoSendEnabled();

  /// Set auto-send enabled setting
  Future<void> setAutoSendEnabled({required bool enabled});

  /// Get clipboard staleness duration in minutes (default: 5)
  Future<int> getClipboardStaleDurationMinutes();

  /// Set clipboard staleness duration in minutes
  Future<void> setClipboardStaleDurationMinutes(int minutes);

  /// Get auto-send target devices (default: all devices)
  /// Returns Set of device types: 'windows', 'macos', 'android', 'ios'
  /// Empty set = send to all devices
  Future<Set<String>> getAutoSendTargetDevices();

  /// Set auto-send target devices
  /// Pass empty set to send to all devices
  Future<void> setAutoSendTargetDevices(Set<String> devices);

  /// Get auto-start enabled setting (default: false)
  Future<bool> getAutoStartEnabled();

  /// Set auto-start enabled setting
  Future<void> setAutoStartEnabled({required bool enabled});

  /// Get auto-receive behavior (default: smart)
  Future<AutoReceiveBehavior> getAutoReceiveBehavior();

  /// Set auto-receive behavior
  Future<void> setAutoReceiveBehavior(AutoReceiveBehavior behavior);

  // ========== FEATURE FLAGS ==========

  /// Check if hybrid mode is enabled (from Supabase app_config table)
  /// Returns false by default if error or not found
  Future<bool> isHybridModeEnabled();

  /// Initialize settings service
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
