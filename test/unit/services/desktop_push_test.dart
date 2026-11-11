import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/clipboard_sync_service.dart';
import 'package:ghostcopy/services/desktop_push_service.dart';
import 'package:ghostcopy/services/device_service.dart';
import 'package:ghostcopy/services/impl/windows_push_service.dart';
import 'package:ghostcopy/services/lifecycle_controller.dart';
import 'package:mocktail/mocktail.dart';

class _Push implements IDesktopPushService {
  _Push({this.starts = true});

  final bool starts;
  // ignore: close_sinks - closed by the group's tearDown
  final StreamController<void> controller = StreamController<void>.broadcast();
  bool disposed = false;

  @override
  Future<bool> start() async => starts;

  @override
  Future<void> reregister() async {}

  @override
  Stream<void> get pushes => controller.stream;

  @override
  void dispose() => disposed = true;
}

class _Sync extends Fake implements IClipboardSyncService {
  @override
  void Function()? onPollFoundClip;

  int checks = 0;

  @override
  void checkForNewClips() => checks++;
}

class _Lifecycle extends Fake implements ILifecycleController {
  @override
  bool desktopPushActive = false;
}

class _Devices extends Mock implements IDeviceService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopPushCoordinator', () {
    late _Push push;
    late _Sync sync;
    late _Lifecycle lifecycle;
    late DesktopPushCoordinator coordinator;

    setUp(() {
      push = _Push();
      sync = _Sync();
      lifecycle = _Lifecycle();
      coordinator = DesktopPushCoordinator(
        push: push,
        sync: sync,
        lifecycle: lifecycle,
      );
    });

    tearDown(() => push.controller.close());

    test('push is not trusted until one has arrived', () async {
      expect(await coordinator.start(), isTrue);
      expect(lifecycle.desktopPushActive, isFalse);

      push.controller.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(lifecycle.desktopPushActive, isTrue);
      expect(sync.checks, 1, reason: 'the push says only that a clip came');
    });

    test('a push that cannot start changes nothing', () async {
      coordinator = DesktopPushCoordinator(
        push: _Push(starts: false),
        sync: sync,
        lifecycle: lifecycle,
      );

      expect(await coordinator.start(), isFalse);
      expect(sync.onPollFoundClip, isNull);
    });

    test('a clip the push announced keeps push trusted', () {
      fakeAsync((async) {
        unawaited(coordinator.start());
        async.flushMicrotasks();
        push.controller.add(null);
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 5));

        sync.onPollFoundClip!();

        expect(lifecycle.desktopPushActive, isTrue);
      });
    });

    test('a clip found with no push before it reopens realtime', () {
      fakeAsync((async) {
        unawaited(coordinator.start());
        async.flushMicrotasks();
        push.controller.add(null);
        // The tray health check finds a clip long after the last push.
        async
          ..flushMicrotasks()
          ..elapse(
            DesktopPushCoordinator.announcedWindow + const Duration(minutes: 1),
          );
        sync.onPollFoundClip!();

        expect(lifecycle.desktopPushActive, isFalse);

        // And the next push brings it back.
        push.controller.add(null);
        async.flushMicrotasks();
        expect(lifecycle.desktopPushActive, isTrue);
      });
    });

    test('an existing poll callback still runs', () async {
      var earlier = 0;
      sync.onPollFoundClip = () => earlier++;
      await coordinator.start();

      sync.onPollFoundClip!();

      expect(earlier, 1);
    });

    test('dispose hands the connection back to realtime', () async {
      await coordinator.start();
      push.controller.add(null);
      await Future<void>.delayed(Duration.zero);

      coordinator.dispose();

      expect(lifecycle.desktopPushActive, isFalse);
      expect(push.disposed, isTrue);
      expect(sync.onPollFoundClip, isNull);
    });
  });

  group('WindowsPushService', () {
    const channel = MethodChannel(WindowsPushService.channelName);
    late _Devices devices;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      devices = _Devices();
      when(
        () => devices.updateWnsChannelUri(any()),
      ).thenAnswer((_) async => true);
      when(() => devices.registerCurrentDevice()).thenAnswer((_) async => true);
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('stores the channel URI on the device row', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'createChannel');
        return {
          'uri': 'https://db5.notify.windows.com/?token=abc',
          'expiresAtMs': 0,
        };
      });
      final service = WindowsPushService(deviceService: devices);
      addTearDown(service.dispose);

      expect(await service.start(), isTrue);
      verify(
        () => devices.updateWnsChannelUri(
          'https://db5.notify.windows.com/?token=abc',
        ),
      ).called(1);
    });

    test('an unpackaged build reports no push', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unpackaged');
      });
      final service = WindowsPushService(deviceService: devices);
      addTearDown(service.dispose);

      expect(await service.start(), isFalse);
      verifyNever(() => devices.updateWnsChannelUri(any()));
    });

    test('a raw notification from the runner becomes a push', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'uri': 'https://db5.notify.windows.com/?token=abc'},
      );
      final service = WindowsPushService(deviceService: devices);
      addTearDown(service.dispose);
      await service.start();
      final received = service.pushes.first;

      await messenger.handlePlatformMessage(
        WindowsPushService.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('received'),
        ),
        (_) {},
      );

      await expectLater(received, completes);
    });

    test('a new account gets the channel on its own row', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'uri': 'https://db5.notify.windows.com/?token=abc'},
      );
      final service = WindowsPushService(deviceService: devices);
      addTearDown(service.dispose);
      await service.start();
      clearInteractions(devices);

      await service.reregister();

      verifyInOrder([
        () => devices.registerCurrentDevice(),
        () => devices.updateWnsChannelUri(
          'https://db5.notify.windows.com/?token=abc',
        ),
      ]);
    });
  });
}
