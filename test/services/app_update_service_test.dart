import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ghostcopy/updater-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppUpdateService service;

  setUp(() {
    service = AppUpdateService(channel: channel);
  });

  tearDown(() {
    service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('a native startup failure does not prevent app startup', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'bad_configuration',
        message: 'Missing signing key',
      );
    });
    await service.initialize();
    expect(service.isAvailable, isFalse);
    await expectLater(
      service.checkForUpdates(),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'an unsuccessful preference change preserves the native preference',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'initialize') {
          return <String, bool>{
            'automaticChecks': true,
            'updateAvailable': false,
          };
        }
        throw PlatformException(code: 'write_failed');
      });
      await service.initialize();
      await expectLater(
        service.setAutomaticChecks(enabled: false),
        throwsA(isA<PlatformException>()),
      );
      expect(service.automaticChecks, isTrue);
    },
  );

  test(
    'scheduled availability and session completion update the reminder',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        return <String, bool>{
          'automaticChecks': false,
          'updateAvailable': false,
        };
      });
      await service.initialize();
      for (final available in [true, false]) {
        final reply = Completer<void>();
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('stateChanged', <String, bool>{
              'automaticChecks': false,
              'updateAvailable': available,
            }),
          ),
          (_) => reply.complete(),
        );
        await reply.future;
        expect(service.updateAvailable, available);
      }
    },
  );

  test(
    'startup finishing after disposal does not notify or resurrect service',
    () async {
      final pending = Completer<Object?>();
      messenger.setMockMethodCallHandler(channel, (_) => pending.future);
      final initialized = service.initialize();
      service.dispose();
      pending.complete(<String, bool>{'automaticChecks': true});
      await initialized;
      expect(service.isAvailable, isFalse);
    },
  );
}
