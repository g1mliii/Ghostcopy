import 'package:flutter/foundation.dart';

export 'impl/app_update_service.dart';

/// macOS update preferences and availability supplied by Sparkle.
abstract class IAppUpdateService extends ChangeNotifier {
  /// Whether Sparkle started successfully for this build.
  bool get isAvailable;

  /// Whether scheduled update checks are enabled.
  bool get automaticChecks;

  /// Whether the menu should offer a pending update.
  bool get updateAvailable;

  /// Start the updater without blocking app startup on failure.
  Future<void> initialize();

  /// Present Sparkle's update dialog, or the startup error if unavailable.
  Future<void> checkForUpdates();

  /// Persist [enabled] using Sparkle's own preferences.
  Future<void> setAutomaticChecks({required bool enabled});
}
