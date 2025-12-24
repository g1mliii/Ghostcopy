export 'impl/auto_start_service.dart';

/// Abstract interface for auto-start functionality
///
/// Manages application startup at system login for desktop platforms.
/// Requirements 10.1, 10.2
abstract class IAutoStartService {
  /// Initialize the auto-start service
  Future<void> initialize();

  /// Check if auto-start is currently enabled
  Future<bool> isEnabled();

  /// Enable auto-start at system login
  /// App will launch in hidden/sleep mode on startup
  Future<void> enable();

  /// Disable auto-start at system login
  Future<void> disable();

  /// Toggle auto-start setting
  Future<void> toggle();

  /// Dispose of the service and clean up resources
  void dispose();
}
