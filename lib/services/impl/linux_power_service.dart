import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../system_power_service.dart';

/// Observes logind sleep and Plasma lock events without polling or privileges.
class LinuxPowerService implements ISystemPowerService {
  LinuxPowerService({DBusClient? system, DBusClient? session})
    : _system = system ?? DBusClient.system(),
      _session = session ?? DBusClient.session();

  final DBusClient _system;
  final DBusClient _session;
  final StreamController<PowerEvent> _events =
      StreamController<PowerEvent>.broadcast();
  StreamSubscription<DBusSignal>? _sleep;
  StreamSubscription<DBusSignal>? _lock;
  bool _disposed = false;

  @override
  Stream<PowerEvent> get powerEventStream => _events.stream;

  @override
  Future<void> initialize() async {
    // Probe first so a missing bus fails inside our exception boundary rather
    // than as an unhandled async error from DBusSignalStream.onListen.
    try {
      await _system.listNames().timeout(const Duration(seconds: 5));
      if (_disposed) return;
      _sleep =
          DBusSignalStream(
            _system,
            sender: 'org.freedesktop.login1',
            path: DBusObjectPath('/org/freedesktop/login1'),
            interface: 'org.freedesktop.login1.Manager',
            name: 'PrepareForSleep',
            signature: DBusSignature('b'),
          ).listen(
            (signal) => _emit(
              signal.values.single.asBoolean()
                  ? PowerEventType.systemSleep
                  : PowerEventType.systemWake,
            ),
            onError: (Object error) =>
                debugPrint('[LinuxPower] Sleep signal failed: $error'),
          );
    } on Exception catch (error) {
      debugPrint('[LinuxPower] Sleep monitoring unavailable: $error');
    }
    try {
      await _session.listNames().timeout(const Duration(seconds: 5));
      if (_disposed) return;
      _lock =
          DBusSignalStream(
            _session,
            sender: 'org.freedesktop.ScreenSaver',
            path: DBusObjectPath('/ScreenSaver'),
            interface: 'org.freedesktop.ScreenSaver',
            name: 'ActiveChanged',
            signature: DBusSignature('b'),
          ).listen(
            (signal) => _emit(
              signal.values.single.asBoolean()
                  ? PowerEventType.screenLock
                  : PowerEventType.screenUnlock,
            ),
            onError: (Object error) =>
                debugPrint('[LinuxPower] Lock signal failed: $error'),
          );
    } on Exception catch (error) {
      debugPrint('[LinuxPower] Lock monitoring unavailable: $error');
    }
  }

  void _emit(PowerEventType type) {
    if (!_disposed) _events.add(PowerEvent(type));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_close());
  }

  Future<void> _close() async {
    await _sleep?.cancel();
    await _lock?.cancel();
    await _system.close();
    await _session.close();
    await _events.close();
  }
}
