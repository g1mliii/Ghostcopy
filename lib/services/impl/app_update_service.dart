import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_update_service.dart';

/// Bridges the macOS native updater. Construct only on macOS.
class AppUpdateService extends IAppUpdateService {
  AppUpdateService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.ghostcopy/updater');

  final MethodChannel _channel;
  bool _available = false;
  bool _automaticChecks = false;
  bool _updateAvailable = false;
  bool _disposed = false;
  String? _startupError;

  @override
  bool get isAvailable => _available;

  @override
  bool get automaticChecks => _automaticChecks;

  @override
  bool get updateAvailable => _updateAvailable;

  @override
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') _applyState(call.arguments);
    });
    try {
      final state = await _channel.invokeMethod<Object?>('initialize');
      if (_disposed) return;
      _available = true;
      _applyState(state);
    } on PlatformException catch (error) {
      _startupError = error.message;
      debugPrint('[AppUpdateService] Could not start updater: $_startupError');
    } on MissingPluginException {
      _startupError = 'Updates are unavailable in this build.';
      debugPrint('[AppUpdateService] Native updater is unavailable');
    }
  }

  void _applyState(Object? value) {
    if (_disposed || value is! Map<Object?, Object?>) return;
    _automaticChecks = value['automaticChecks'] == true;
    _updateAvailable = value['updateAvailable'] == true;
    notifyListeners();
  }

  @override
  Future<void> checkForUpdates() async {
    if (!_available) {
      throw PlatformException(
        code: 'updater_unavailable',
        message: _startupError ?? 'Updates are unavailable in this build.',
      );
    }
    await _channel.invokeMethod<void>('checkForUpdates');
  }

  @override
  Future<void> setAutomaticChecks({required bool enabled}) async {
    final state = await _channel.invokeMethod<Object?>(
      'setAutomaticChecks',
      enabled,
    );
    _applyState(state);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
