export 'impl/settings_service.dart';

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

  /// Initialize settings service
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
