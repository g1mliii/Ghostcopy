import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/store_age_signal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StoreAgeSignal.fromPlatform', () {
    const apple = {'shared': true, 'store': 'app_store'};

    test('an adult lower bound is adult and carries no store reference', () {
      final signal = StoreAgeSignal.fromPlatform({
        ...apple,
        'ageLower': 18,
        'storeRef': '1',
      });
      expect(signal.status, StoreAgeStatus.adult);
      expect(signal.storeRef, isNull);
      expect(signal.ageChoices, isEmpty);
    });

    test('a minor band limits the choices and keeps the reference', () {
      final signal = StoreAgeSignal.fromPlatform({
        ...apple,
        'ageLower': 16,
        'ageUpper': 17,
        'storeRef': '704289572311430368',
        'significantChangeConsentRequired': true,
      });
      expect(signal.status, StoreAgeStatus.minor);
      expect(signal.store, AppStore.appStore);
      expect(signal.ageChoices, ['16', '17']);
      expect(signal.storeRef, '704289572311430368');
      expect(signal.significantChangeConsentRequired, isTrue);
    });

    test('under the lowest gate offers Under 5 and 5 to the upper bound', () {
      final signal = StoreAgeSignal.fromPlatform({...apple, 'ageUpper': 12});
      expect(signal.status, StoreAgeStatus.minor);
      expect(signal.ageChoices, [
        'Under 5',
        for (var i = 5; i <= 12; i++) '$i',
      ]);
    });

    test('Play pending or declined approval blocks setup', () {
      for (final change in ['pending', 'declined']) {
        final signal = StoreAgeSignal.fromPlatform({
          'shared': true,
          'store': 'google_play',
          'ageLower': 13,
          'ageUpper': 15,
          'significantChange': change,
        });
        expect(signal.status, StoreAgeStatus.notApproved);
        expect(signal.pending, change == 'pending');
        expect(signal.storeRef, isNull);
      }
      expect(
        StoreAgeSignal.fromPlatform({
          'shared': true,
          'store': 'google_play',
          'ageLower': 13,
          'ageUpper': 15,
          'significantChange': 'approved',
        }).status,
        StoreAgeStatus.minor,
      );
    });

    test('anything unusable falls back to the self-declared flow', () {
      for (final value in <Map<Object?, Object?>?>[
        null,
        {'shared': false},
        {'shared': true},
        {'shared': true, 'store': 'steam', 'ageLower': 18},
        {...apple, 'ageLower': '18'},
        {...apple},
        {...apple, 'ageLower': 16},
        {...apple, 'ageLower': 15, 'ageUpper': 13},
      ]) {
        expect(
          StoreAgeSignal.fromPlatform(value).status,
          StoreAgeStatus.unavailable,
          reason: '$value',
        );
      }
    });

    test('an oversized store reference is dropped', () {
      final signal = StoreAgeSignal.fromPlatform({
        ...apple,
        'ageUpper': 12,
        'storeRef': 'x' * 129,
      });
      expect(signal.storeRef, isNull);
    });
  });

  group('StoreAgeSignalService', () {
    const channel = MethodChannel('com.ghostcopy/store_age');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('unsupported platforms never call the channel', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return null;
      });
      final service = StoreAgeSignalService(supported: false);
      expect((await service.request()).status, StoreAgeStatus.unavailable);
      expect(
        await service.significantChange(version: 'v', description: 'd'),
        SignificantChangeStatus.notRequired,
      );
      expect(calls, 0);
    });

    test(
      'maps the native answer and passes significant-change arguments',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'requestAgeSignal'
              ? {'shared': true, 'store': 'app_store', 'ageLower': 18}
              : 'pending';
        });
        final service = StoreAgeSignalService(supported: true);
        expect((await service.request()).status, StoreAgeStatus.adult);
        expect(
          await service.significantChange(
            version: 'v2',
            description: 'd',
            ask: true,
          ),
          SignificantChangeStatus.pending,
        );
        expect(calls.last.arguments, {
          'version': 'v2',
          'description': 'd',
          'ask': true,
        });
      },
    );

    test('errors and an older native build fall back', () async {
      final service = StoreAgeSignalService(supported: true);
      // No handler: MissingPluginException, as on a build without the channel.
      expect((await service.request()).status, StoreAgeStatus.unavailable);
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'error');
      });
      expect((await service.request()).status, StoreAgeStatus.unavailable);
      expect(
        await service.significantChange(version: 'v', description: 'd'),
        SignificantChangeStatus.notRequired,
      );
    });
  });
}
