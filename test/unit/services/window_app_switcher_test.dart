import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/window_service.dart';

/// The ordinary pin puts the Spotlight in Cmd-Tab and Alt-Tab while it is up,
/// and nothing else does. Driven through window_manager's real method
/// channel, recording what reaches the platform.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const display = <String, Object?>{
    'id': '1',
    'size': {'width': 1440.0, 'height': 900.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1440.0, 'height': 860.0},
    'scaleFactor': 2.0,
  };
  const presence = MethodChannel('com.ghostcopy/app_presence');

  /// What reached the platform, either way it went: 'in' or 'out' of the
  /// app switcher. macOS uses AppPresence, Windows setSkipTaskbar.
  late List<String> switcher;

  setUp(() {
    switcher = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(presence, (call) async {
          switcher.add(call.method == 'enterAppSwitcher' ? 'in' : 'out');
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          screens,
          (call) async => switch (call.method) {
            'getPrimaryDisplay' => display,
            'getCursorScreenPoint' => {'dx': 700.0, 'dy': 400.0},
            'getAllDisplays' => {
              'displays': [display],
            },
            _ => null,
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'setSkipTaskbar':
              final skip =
                  (call.arguments as Map<Object?, Object?>)['isSkipTaskbar']!
                      as bool;
              switcher.add(skip ? 'out' : 'in');
              return null;

            case 'getPosition':
            case 'getBounds':
              return <String, Object?>{
                'x': 0.0,
                'y': 0.0,
                'width': 500.0,
                'height': 400.0,
              };
            default:
              // isVisible, isFocused, isFullScreen... - all false here.
              return call.method.startsWith('is') ? false : null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(channel, null)
      ..setMockMethodCallHandler(screens, null)
      ..setMockMethodCallHandler(presence, null);
  });

  test('an ordinary pin joins the app switcher only while it is up', () async {
    final window = WindowService();

    await window.setPinned(pinned: true, onTop: false);
    expect(switcher, isEmpty, reason: 'pinned, but not on screen yet');

    await window.showSpotlight();
    expect(switcher, ['in'], reason: 'up and pinned: Cmd-Tab, Alt-Tab');

    await window.hideSpotlight();
    expect(switcher, ['in', 'out'], reason: 'hidden: a tray app again');
  });

  test('the on-top pin and no pin stay out of it', () async {
    final window = WindowService();

    await window.setPinned(pinned: true, onTop: true);
    await window.showSpotlight();
    await window.setPinned(pinned: false, onTop: false);

    expect(switcher, isEmpty);
  });

  test('pinning while up joins at once, and on-top leaves at once', () async {
    final window = WindowService();
    await window.showSpotlight();

    await window.setPinned(pinned: true, onTop: false);
    expect(switcher, ['in']);

    // On top stays up indefinitely, so it cannot wait for a hide.
    await window.setPinned(pinned: true, onTop: true);
    expect(switcher, ['in', 'out']);

    await window.hideSpotlight();
    // macOS leaves again at the hide, the full way; Windows has nothing to
    // redo.
    expect(switcher, Platform.isMacOS ? ['in', 'out', 'out'] : ['in', 'out']);
  });

  test(
    'a failed change is tried again, not taken as done',
    () async {
      var failNext = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(presence, (call) async {
            if (failNext) {
              failNext = false;
              throw PlatformException(code: 'failed');
            }
            switcher.add(call.method == 'enterAppSwitcher' ? 'in' : 'out');
            return null;
          });
      final window = WindowService();
      await window.setPinned(pinned: true, onTop: false);

      await window.showSpotlight(); // the first attempt fails
      await window.setPinned(pinned: true, onTop: false); // tried again

      expect(switcher, ['in']);
    },
    skip: !Platform.isMacOS ? 'drives the macOS channel' : false,
  );

  test('the tray menu borrowing the window takes it out', () async {
    final window = WindowService();
    await window.setPinned(pinned: true, onTop: false);
    await window.showSpotlight();

    await window.setFramelessForTrayMenu();

    expect(switcher, ['in', 'out']);
  });
}
