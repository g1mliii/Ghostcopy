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

  /// Initialize settings service
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
