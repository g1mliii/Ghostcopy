import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../auto_start_service.dart';

/// Concrete implementation of IAutoStartService using launch_at_startup package
///
/// Manages application auto-start functionality for Windows and macOS.
/// The app will launch in hidden/sleep mode when started at system login.
///
/// Requirements:
/// - 10.1: Register app to start at OS login (Windows & macOS)
/// - 10.2: Launch in hidden/sleep mode
class AutoStartService implements IAutoStartService {
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      _initialized = true;
      return;
    }

    try {
      // Get package info for app configuration
      final packageInfo = await PackageInfo.fromPlatform();

      // Configure launch_at_startup with app details
      launchAtStartup.setup(
        appName: packageInfo.appName,
        appPath: Platform.resolvedExecutable,
        // Optional: Add launch arguments to identify startup launch
        // This allows the app to know it was launched at startup
        args: ['--launched-at-startup'],
      );

      _initialized = true;
      debugPrint('AutoStartService initialized');
    } on Exception catch (e) {
      debugPrint('Failed to initialize AutoStartService: $e');
      // Don't rethrow - auto-start is a non-critical feature
      _initialized = true;
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('AutoStartService not initialized. Call initialize() first.');
    }
  }

  @override
  Future<bool> isEnabled() async {
    _ensureInitialized();

    if (!_isDesktop()) {
      return false;
    }

    try {
      return await launchAtStartup.isEnabled();
    } on Exception catch (e) {
      debugPrint('Failed to check auto-start status: $e');
      return false;
    }
  }

  @override
  Future<void> enable() async {
    _ensureInitialized();

    if (!_isDesktop()) {
      return;
    }

    try {
      await launchAtStartup.enable();
      debugPrint('Auto-start enabled');
    } on Exception catch (e) {
      debugPrint('Failed to enable auto-start: $e');
      // Don't rethrow - let the app continue
    }
  }

  @override
  Future<void> disable() async {
    _ensureInitialized();

    if (!_isDesktop()) {
      return;
    }

    try {
      await launchAtStartup.disable();
      debugPrint('Auto-start disabled');
    } on Exception catch (e) {
      debugPrint('Failed to disable auto-start: $e');
      // Don't rethrow - let the app continue
    }
  }

  @override
  Future<void> toggle() async {
    _ensureInitialized();

    final currentState = await isEnabled();
    if (currentState) {
      await disable();
    } else {
      await enable();
    }
  }

  @override
  void dispose() {
    _initialized = false;
  }

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
