import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/repositories/impl/clipboard_repository.dart';
import 'package:ghostcopy/services/impl/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression tests for the auto-send destination list.
///
/// The valid device types were written out by hand in three places, and the
/// copies drifted: the selectors offered Linux while the setter validated
/// against a four-platform set, so picking a Linux destination threw and the
/// choice was never persisted - the chip stayed lit until the screen was
/// reopened, and the user's Linux machines quietly kept receiving nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService();
    await settings.initialize();
  });

  group('auto-send target devices', () {
    test('every canonical device type can be persisted', () async {
      // The whole point: whatever the selectors can offer, the setter accepts.
      for (final device in ClipboardRepository.validDeviceTypes) {
        await settings.setAutoSendTargetDevices({device});
        expect(
          await settings.getAutoSendTargetDevices(),
          equals({device}),
          reason: '$device is a valid device type but did not round-trip',
        );
      }
    });

    test('linux specifically round-trips', () async {
      // Named separately because linux is the one that was missing, and a
      // loop over a list that lost it again would still pass silently.
      await settings.setAutoSendTargetDevices({'linux', 'macos'});

      expect(
        await settings.getAutoSendTargetDevices(),
        equals({'linux', 'macos'}),
      );
    });

    test('the expanded all-devices set persists', () async {
      // What the mobile screen writes when the sentinel is expanded and one
      // destination is then turned off. It must not throw on any member.
      final expanded = ClipboardRepository.validDeviceTypes.toSet()
        ..remove('ios');

      await settings.setAutoSendTargetDevices(expanded);

      expect(await settings.getAutoSendTargetDevices(), equals(expanded));
    });

    test('an unknown device type is still rejected', () async {
      // Widening the list must not turn the validation off altogether.
      expect(
        () => settings.setAutoSendTargetDevices({'beos'}),
        throwsArgumentError,
      );
    });
  });
}
