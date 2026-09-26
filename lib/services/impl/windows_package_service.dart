import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../windows_package_service.dart';

/// Talks to `com.ghostcopy.app/packaging` in the Windows runner.
///
/// Every method answers a safe default rather than throwing when the channel
/// is missing: off Windows there is no handler at all, and an unpackaged
/// Windows build answers [WindowsStartupState.unavailable] by design. Callers
/// are startup paths and a settings toggle, neither of which should be able to
/// take the app down.
class WindowsPackageService implements IWindowsPackageService {
  /// [isWindows] exists so the class can be exercised off Windows, where the
  /// suite runs in CI. It is not a feature switch - production always takes
  /// the default.
  WindowsPackageService({MethodChannel? channel, bool? isWindows})
    : _channel = channel ?? const MethodChannel(_channelName),
      _isWindows = isWindows ?? Platform.isWindows;

  static const String _channelName = 'com.ghostcopy.app/packaging';

  final MethodChannel _channel;
  final bool _isWindows;

  /// Cached because it cannot change while the process lives, and it is asked
  /// on several startup paths.
  bool? _isPackaged;

  @override
  Future<bool> isPackaged() async {
    if (!_isWindows) return false;
    final cached = _isPackaged;
    if (cached != null) return cached;

    final result = await _invoke<bool>('isPackaged') ?? false;
    _isPackaged = result;
    return result;
  }

  @override
  Future<WindowsStartupState> startupState() => _startupCall('startupState');

  @override
  Future<WindowsStartupState> enableStartup() => _startupCall('enableStartup');

  @override
  Future<WindowsStartupState> disableStartup() =>
      _startupCall('disableStartup');

  Future<WindowsStartupState> _startupCall(String method) async {
    if (!_isWindows) return WindowsStartupState.unavailable;
    final name = await _invoke<String>(method);
    return _parse(name);
  }

  Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      // No handler registered - not Windows, or an older runner.
      return null;
    } on PlatformException catch (e) {
      debugPrint('[WindowsPackage] $method failed: ${e.message}');
      return null;
    }
  }

  static WindowsStartupState _parse(String? name) =>
      WindowsStartupState.values.asNameMap()[name] ??
      WindowsStartupState.unavailable;
}
