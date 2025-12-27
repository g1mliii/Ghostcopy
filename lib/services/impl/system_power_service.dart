import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../system_power_service.dart';

/// Implementation of SystemPowerService using platform channels
///
/// Listens to native OS power events via MethodChannel:
/// - Windows: WM_POWERBROADCAST and WTS_SESSION notifications
/// - macOS: NSWorkspace notifications
class SystemPowerService implements ISystemPowerService {
  static const _channel = MethodChannel('com.ghostcopy.app/power');

  final _eventController = StreamController<PowerEvent>.broadcast();

  @override
  Stream<PowerEvent> get powerEventStream => _eventController.stream;

  @override
  Future<void> initialize() async {
    if (!_isDesktop()) {
      debugPrint('[SystemPower] Skipping initialization (not desktop platform)');
      return;
    }

    debugPrint('[SystemPower] 🔌 Initializing power monitoring...');

    // Set up method call handler for native events
    _channel.setMethodCallHandler(_handleMethodCall);

    try {
      // Start listening to platform power events
      await _channel.invokeMethod<void>('startListening');
      debugPrint('[SystemPower] ✅ Power monitoring initialized');
    } on PlatformException catch (e) {
      debugPrint('[SystemPower] ⚠️  Failed to initialize: ${e.message}');
    }
  }

  /// Handle incoming method calls from native platform code
  Future<void> _handleMethodCall(MethodCall call) async {
    debugPrint('[SystemPower] 📥 Received event: ${call.method}');

    switch (call.method) {
      // Windows events
      case 'systemSuspend':
        _eventController.add(PowerEvent(PowerEventType.systemSleep));
        break;
      case 'systemResume':
        _eventController.add(PowerEvent(PowerEventType.systemWake));
        break;
      case 'sessionLock':
        _eventController.add(PowerEvent(PowerEventType.screenLock));
        break;
      case 'sessionUnlock':
        _eventController.add(PowerEvent(PowerEventType.screenUnlock));
        break;

      // macOS events
      case 'willSleep':
        _eventController.add(PowerEvent(PowerEventType.systemSleep));
        break;
      case 'didWake':
        _eventController.add(PowerEvent(PowerEventType.systemWake));
        break;
      case 'screensDidLock':
        _eventController.add(PowerEvent(PowerEventType.screenLock));
        break;
      case 'screensDidUnlock':
        _eventController.add(PowerEvent(PowerEventType.screenUnlock));
        break;

      default:
        debugPrint('[SystemPower] ⚠️  Unknown event: ${call.method}');
    }
  }

  @override
  void dispose() {
    debugPrint('[SystemPower] 🗑️  Disposing power monitoring');

    // Clear method call handler to prevent memory leaks
    _channel.setMethodCallHandler(null);

    // Close stream controller
    _eventController.close();
  }

  /// Check if running on desktop platform
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }
}
