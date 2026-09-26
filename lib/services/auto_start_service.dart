export 'impl/auto_start_service.dart';

/// Who holds launch at login, when it is not this app's to change.
enum AutoStartLock {
  /// The app's own toggle decides.
  none,

  /// Turned off in Task Manager's Startup apps. Windows will not let the app
  /// override that - only the user can turn it back on, there.
  disabledByUser,

  /// Set by an administrator's policy, on or off.
  byPolicy,
}

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

  /// Whether something outside the app has fixed launch at login, so that
  /// [enable] and [disable] cannot change it. Only a packaged Windows build
  /// can be locked; everywhere else this is [AutoStartLock.none].
  Future<AutoStartLock> lock();

  /// Dispose of the service and clean up resources
  void dispose();
}
