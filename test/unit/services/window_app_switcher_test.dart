import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/window_service.dart';

/// The ordinary pin puts the Spotlight in Cmd-Tab and Alt-Tab while it is up,
/// and nothing else does. Driven through the real method channels, recording
/// what reaches the platform: AppPresence on macOS, setSkipTaskbar elsewhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const windowChannel = MethodChannel('window_manager');
  const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const presence = MethodChannel('com.ghostcopy/app_presence');
  const display = <String, Object?>{
    'id': '1',
    'size': {'width': 1440.0, 'height': 900.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1440.0, 'height': 860.0},
    'scaleFactor': 2.0,
  };

  /// 'in' or 'out' of the app switcher, in the order the platform got them.
  late List<String> switcher;

  /// Return true to make the next platform call fail.
  late bool Function() failWhen;

  /// Set to hold the next platform call until it completes.
  Completer<void>? hold;

  Future<void> record({required bool inSwitcher}) async {
    final gate = hold;
    hold = null;
    if (gate != null) await gate.future;
    if (failWhen()) throw PlatformException(code: 'failed');
    switcher.add(inSwitcher ? 'in' : 'out');
  }

  setUp(() {
    switcher = [];
    failWhen = () => false;
    hold = null;
    messenger
      ..setMockMethodCallHandler(presence, (call) async {
        await record(inSwitcher: call.arguments as bool);
        return null;
      })
      ..setMockMethodCallHandler(
        screens,
        (call) async => switch (call.method) {
          'getPrimaryDisplay' => display,
          'getCursorScreenPoint' => {'dx': 700.0, 'dy': 400.0},
          'getAllDisplays' => {
            'displays': [display],
          },
          _ => null,
        },
      )
      ..setMockMethodCallHandler(windowChannel, (call) async {
        switch (call.method) {
          case 'setSkipTaskbar':
            final skip =
                (call.arguments as Map<Object?, Object?>)['isSkipTaskbar']!
                    as bool;
            await record(inSwitcher: !skip);
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
    messenger
      ..setMockMethodCallHandler(windowChannel, null)
      ..setMockMethodCallHandler(screens, null)
      ..setMockMethodCallHandler(presence, null);
  });

  Future<WindowService> pinnedAndUp() async {
    final window = WindowService();
    await window.setPinned(pinned: true, onTop: false);
    await window.showSpotlight();
    return window;
  }

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

  test('choosing on-top while up leaves at once', () async {
    // On top can stay up indefinitely, so it cannot wait for a hide.
    final window = await pinnedAndUp();

    await window.setPinned(pinned: true, onTop: true);
    await window.hideSpotlight();

    expect(switcher, ['in', 'out']);
  });

  test('the tray menu borrowing the window takes it out', () async {
    final window = await pinnedAndUp();

    await window.setFramelessForTrayMenu();

    expect(switcher, ['in', 'out']);
  });

  test('a failed change is tried again, not taken as done', () async {
    var failures = 1;
    failWhen = () => failures-- > 0;
    final window = await pinnedAndUp(); // the first attempt fails

    await window.setPinned(pinned: true, onTop: false); // tried again

    expect(switcher, ['in']);
  });

  test('a hide right after a show settles on the hide', () async {
    final window = WindowService();
    await window.setPinned(pinned: true, onTop: false);
    final entering = Completer<void>();
    hold = entering;

    final showing = window.showSpotlight(); // its "in" is held
    await pumpEventQueue();
    final hiding = window.hideSpotlight();
    entering.complete();
    await Future.wait([showing, hiding]);

    expect(switcher, ['in', 'out']);
  });

  test('macOS goes through AppPresence, elsewhere setSkipTaskbar', () async {
    final calls = <String>[];
    messenger
      ..setMockMethodCallHandler(presence, (call) async {
        calls.add('presence');
        return null;
      })
      ..setMockMethodCallHandler(windowChannel, (call) async {
        if (call.method == 'setSkipTaskbar') calls.add('skipTaskbar');
        if (call.method == 'getBounds' || call.method == 'getPosition') {
          return <String, Object?>{
            'x': 0.0,
            'y': 0.0,
            'width': 500.0,
            'height': 400.0,
          };
        }
        return call.method.startsWith('is') ? false : null;
      });

    await pinnedAndUp();

    expect(calls, [if (Platform.isMacOS) 'presence' else 'skipTaskbar']);
  });
}
