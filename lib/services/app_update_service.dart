import 'package:flutter/foundation.dart';

export 'impl/app_update_service.dart';

/// Desktop update preferences and availability.
abstract class IAppUpdateService extends ChangeNotifier {
  /// Whether updating is supported by this installation.
  bool get isAvailable;

  /// Whether scheduled update checks are enabled.
  bool get automaticChecks;

  /// Whether the menu should offer a pending update.
  bool get updateAvailable;

  /// Start the updater without blocking app startup on failure.
  Future<void> initialize();

  /// Present the platform's update flow, or its availability error.
  Future<void> checkForUpdates();

  /// Persist automatic update checks using [enabled].
  Future<void> setAutomaticChecks({required bool enabled});
}
