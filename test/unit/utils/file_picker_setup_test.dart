import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/file_picker_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  late List<String> calls;

  setUp(() {
    calls = [];
    // The macOS implementation, whatever the host running the tests.
    FilePickerMacOS.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('macOS skips the entitlement check before any panel opens', () async {
    await prepareFilePicker(isMacOS: true);
    expect(calls, ['skipEntitlementsChecks']);
  });

  test('nothing is sent on other platforms', () async {
    await prepareFilePicker(isMacOS: false);
    expect(calls, isEmpty);
  });

  test('a failure to skip is not fatal to startup', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'boom');
        });
    await expectLater(prepareFilePicker(isMacOS: true), completes);
  });

  // The regression: the sandbox was removed and its user-selected-files
  // entitlements with it, and nothing noticed that file_picker demands them.
  // If the macOS app ships without them again, startup must still skip the
  // check - or they have to come back.
  test('without the file entitlements, startup skips the check', () {
    const keys = [
      'com.apple.security.files.user-selected.read-only',
      'com.apple.security.files.user-selected.read-write',
    ];
    for (final name in ['Release', 'DebugProfile']) {
      final entitlements = File(
        'macos/Runner/$name.entitlements',
      ).readAsStringSync();
      final hasFileEntitlement = keys.any(
        (key) => entitlements.contains('<key>$key</key>'),
      );
      if (hasFileEntitlement) continue;
      expect(
        File('lib/main.dart').readAsStringSync(),
        contains('prepareFilePicker(isMacOS: Platform.isMacOS)'),
        reason:
            '$name.entitlements has no user-selected-files entitlement, so '
            'file_picker refuses every panel unless main() skips its check',
      );
    }
  });
}
