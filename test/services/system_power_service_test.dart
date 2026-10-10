import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/system_power_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ghostcopy.app/power');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('missing native power bridge does not abort desktop startup', () async {
    final service = SystemPowerService();
    addTearDown(service.dispose);
    // No handler: this is the MissingPluginException raised by the Linux
    // runner until its native power monitoring is implemented.
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(service.initialize(), completes);
  });

  test('native power initialization failure remains nonfatal', () async {
    final service = SystemPowerService();
    addTearDown(service.dispose);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(service.initialize(), completes);
  });
}
