import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../auto_start_service.dart';
import '../windows_package_service.dart';
import 'windows_package_service.dart';

/// Concrete implementation of IAutoStartService using launch_at_startup package
///
/// Manages application auto-start functionality for Windows and macOS.
/// The app will launch in hidden/sleep mode when started at system login.
///
/// Requirements:
/// - 10.1: Register app to start at OS login (Windows & macOS)
/// - 10.2: Launch in hidden/sleep mode
class AutoStartService implements IAutoStartService {
  AutoStartService({IWindowsPackageService? windowsPackageService})
    : _windowsPackage = windowsPackageService ?? WindowsPackageService();

  /// Decides which of the two Windows paths below is in use.
  final IWindowsPackageService _windowsPackage;

  bool _initialized = false;

  /// True once [initialize] has found this to be a packaged Windows build.
  ///
  /// launch_at_startup has no usable answer there. Its Windows backend writes
  /// the HKCU Run key, which MSIX virtualizes into the package's private hive
  /// so Windows never reads it; its MSIX mode is no better, dropping a
  /// Startup-folder shortcut that points at the versioned WindowsApps path -
  /// a path every Store update moves, leaving a shortcut to an executable that
  /// is no longer there. The supported answer is the <uap5:StartupTask> in the
  /// package manifest, driven through IWindowsPackageService.
  bool _usePackagedStartup = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    // Only initialize on desktop platforms
    if (!_isDesktop()) {
      _initialized = true;
      return;
    }

    try {
      _usePackagedStartup = await _windowsPackage.isPackaged();
      if (_usePackagedStartup) {
        _initialized = true;
        debugPrint('AutoStartService initialized (packaged StartupTask)');
        return;
      }

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
      throw StateError(
        'AutoStartService not initialized. Call initialize() first.',
      );
    }
  }

  @override
  Future<bool> isEnabled() async {
    _ensureInitialized();

    if (!_isDesktop()) {
      return false;
    }

    if (_usePackagedStartup) {
      return (await _windowsPackage.startupState()).isOn;
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

    if (_usePackagedStartup) {
      // The state that comes back is the truth, not the request: a user who
      // turned the entry off in Task Manager's Startup tab keeps it off, and
      // RequestEnableAsync reports that rather than failing.
      final state = await _windowsPackage.enableStartup();
      debugPrint('Auto-start (packaged) requested, now: ${state.name}');
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

    if (_usePackagedStartup) {
      final state = await _windowsPackage.disableStartup();
      debugPrint('Auto-start (packaged) disabled, now: ${state.name}');
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
    _usePackagedStartup = false;
  }

  /// Check if running on desktop platform (Windows or macOS)
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
