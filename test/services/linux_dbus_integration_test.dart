import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/hotkey_service.dart';
import 'package:ghostcopy/services/impl/linux_hotkey_service.dart';
import 'package:ghostcopy/services/impl/linux_power_service.dart';
import 'package:ghostcopy/services/system_power_service.dart';

class _Session extends DBusObject {
  _Session(super.path);
  bool closed = false;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name == 'Close') {
      closed = true;
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

class _Portal extends DBusObject {
  _Portal() : super(DBusObjectPath('/org/freedesktop/portal/desktop'));
  final List<_Session> sessions = [];
  bool denyNext = false;
  bool configureCalled = false;
  String? preferred;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      DBusGetPropertyResponse(const DBusUint32(2));

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.name == 'ConfigureShortcuts') {
      configureCalled = true;
      return DBusMethodSuccessResponse();
    }
    final options = methodCall.values.last.asStringVariantDict();
    final sender = methodCall.sender!.substring(1).replaceAll('.', '_');
    final request = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/$sender/${options['handle_token']!.asString()}',
    );
    final result = <String, DBusValue>{};
    var status = 0;
    if (methodCall.name == 'CreateSession') {
      final session = _Session(
        DBusObjectPath(
          '/org/freedesktop/portal/desktop/session/$sender/${options['session_handle_token']!.asString()}',
        ),
      );
      sessions.add(session);
      await client!.registerObject(session);
      result['session_handle'] = DBusString(session.path.value);
    } else if (methodCall.name == 'BindShortcuts') {
      final shortcuts = methodCall.values[1];
      final properties = shortcuts
          .asArray()
          .single
          .asStruct()[1]
          .asStringVariantDict();
      preferred = properties['preferred_trigger']!.asString();
      if (denyNext) {
        status = 1;
        denyNext = false;
      } else {
        result['shortcuts'] = shortcuts;
      }
    } else {
      return DBusMethodErrorResponse.unknownMethod();
    }
    // Deliberately emit BEFORE returning the method response. The client must
    // already be listening or this portal reply would be lost forever.
    await client!.emitSignal(
      path: request,
      interface: 'org.freedesktop.portal.Request',
      name: 'Response',
      values: [DBusUint32(status), DBusDict.stringVariant(result)],
    );
    return DBusMethodSuccessResponse([request]);
  }

  Future<void> activate(DBusObjectPath session) =>
      emitSignal('org.freedesktop.portal.GlobalShortcuts', 'Activated', [
        session,
        const DBusString('spotlight'),
        const DBusUint64(1),
        DBusDict.stringVariant({}),
      ]);
}

void main() {
  group(
    'Linux desktop D-Bus protocol',
    () {
      late DBusServer bus;
      late DBusAddress address;
      late DBusClient daemon;

      setUp(() async {
        bus = DBusServer();
        address = await bus.listenAddress(DBusAddress.tcp('127.0.0.1'));
        daemon = DBusClient(address);
      });
      tearDown(() async {
        await daemon.close();
        await bus.close();
      });

      test(
        'immediate portal replies, activation, denied rebind and close',
        () async {
          final portal = _Portal();
          await daemon.requestName('org.freedesktop.portal.Desktop');
          await daemon.registerObject(portal);
          final service = LinuxHotkeyService(client: DBusClient(address));
          addTearDown(service.dispose);
          const hotkey = HotKey(key: 's', ctrl: true, shift: true);
          final activated = Completer<void>();
          await service.registerHotkey(hotkey, () {
            if (!activated.isCompleted) activated.complete();
          });
          expect(portal.preferred, 'CTRL+SHIFT+s');
          await portal.activate(portal.sessions.first.path);
          await activated.future.timeout(const Duration(seconds: 2));
          await service.configure();
          expect(portal.configureCalled, isTrue);
          portal.denyNext = true;
          await expectLater(
            service.registerHotkey(const HotKey(key: 'k', ctrl: true), () {}),
            throwsFormatException,
          );
          expect(portal.sessions.first.closed, isFalse);
          expect(portal.sessions.last.closed, isTrue);
          await service.unregisterHotkey(hotkey);
          expect(portal.sessions.first.closed, isTrue);
        },
        timeout: const Timeout(Duration(seconds: 15)),
      );

      test('maps logind and Plasma signals to lifecycle events', () async {
        await daemon.requestName('org.freedesktop.login1');
        await daemon.requestName('org.freedesktop.ScreenSaver');
        final system = DBusClient(address);
        final session = DBusClient(address);
        final service = LinuxPowerService(system: system, session: session);
        final events = <PowerEventType>[];
        final delivered = Completer<void>();
        final subscription = service.powerEventStream.listen((event) {
          events.add(event.type);
          if (events.length == 4) delivered.complete();
        });
        await service.initialize();
        await system.ping();
        await session.ping();
        for (final sleeping in [true, false]) {
          await daemon.emitSignal(
            path: DBusObjectPath('/org/freedesktop/login1'),
            interface: 'org.freedesktop.login1.Manager',
            name: 'PrepareForSleep',
            values: [DBusBoolean(sleeping)],
          );
        }
        for (final locked in [true, false]) {
          await daemon.emitSignal(
            path: DBusObjectPath('/ScreenSaver'),
            interface: 'org.freedesktop.ScreenSaver',
            name: 'ActiveChanged',
            values: [DBusBoolean(locked)],
          );
        }
        await delivered.future.timeout(const Duration(seconds: 3));
        expect(events, containsAll(PowerEventType.values));
        await subscription.cancel();
        final closed = service.powerEventStream.drain<void>();
        service.dispose();
        await closed;
      });
    },
    skip: !Platform.isLinux ? 'D-Bus authentication requires Linux UID' : false,
  );
}
