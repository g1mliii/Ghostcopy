import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/windows_package_service.dart';
import 'package:ghostcopy/services/windows_package_service.dart';

/// Records what Dart asked the runner for, and answers with whatever the test
/// sets. `isWindows: true` is passed explicitly throughout so these run on the
/// Linux runner that executes the suite in CI.
class _FakeRunner {
  _FakeRunner(this.channel);

  final MethodChannel channel;
  final List<String> calls = [];
  Object? reply;
  Object? Function(String method)? onCall;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          final handler = onCall;
          if (handler != null) return handler(call.method);
          return reply;
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.ghostcopy.app/packaging');
  late _FakeRunner runner;

  setUp(() {
    runner = _FakeRunner(channel)..install();
  });

  tearDown(() => runner.remove());

  WindowsPackageService build() =>
      WindowsPackageService(channel: channel, isWindows: true);

  group('isPackaged', () {
    test('reports what the runner says', () async {
      runner.reply = true;
      expect(await build().isPackaged(), isTrue);
      expect(runner.calls, ['isPackaged']);
    });

    test('is asked once and cached', () async {
      runner.reply = true;
      final service = build();
      await service.isPackaged();
      await service.isPackaged();
      await service.isPackaged();
      expect(runner.calls, ['isPackaged']);
    });

    test('is false off Windows, without touching the channel', () async {
      runner.reply = true;
      final service = WindowsPackageService(
        channel: channel,
        isWindows: false,
      );
      expect(await service.isPackaged(), isFalse);
      expect(runner.calls, isEmpty);
    });

    // An older runner, or any build without the handler. Treating this as
    // "not packaged" keeps the unpackaged registry path, which is the one
    // that works outside a package.
    test('falls back to false when no handler is registered', () async {
      runner.remove();
      expect(await build().isPackaged(), isFalse);
    });
  });

  group('startup state', () {
    test('every WinRT state round-trips by name', () async {
      for (final expected in WindowsStartupState.values) {
        runner.reply = expected.name;
        expect(await build().startupState(), expected, reason: expected.name);
      }
    });

    test('an unrecognised name degrades to unavailable', () async {
      runner.reply = 'somethingNewInAFutureWindows';
      expect(await build().startupState(), WindowsStartupState.unavailable);
    });

    test('a platform error degrades to unavailable', () async {
      runner.onCall = (_) => throw PlatformException(code: 'winrt_failed');
      expect(await build().startupState(), WindowsStartupState.unavailable);
    });

    test('enable and disable each call their own method', () async {
      runner.onCall = (method) =>
          method == 'enableStartup' ? 'enabled' : 'disabled';
      final service = build();
      expect(await service.enableStartup(), WindowsStartupState.enabled);
      expect(await service.disableStartup(), WindowsStartupState.disabled);
      expect(runner.calls, ['enableStartup', 'disableStartup']);
    });

    // The point of surfacing the resulting state rather than a bool: asking
    // to enable does not mean it got enabled.
    test('a user refusal survives an enable request', () async {
      runner.reply = 'disabledByUser';
      final state = await build().enableStartup();
      expect(state, WindowsStartupState.disabledByUser);
      expect(state.isOn, isFalse);
      expect(state.isLockedByOther, isTrue);
    });
  });

  group('state predicates', () {
    test('isOn covers exactly the two enabled states', () {
      expect(
        WindowsStartupState.values.where((s) => s.isOn),
        unorderedEquals([
          WindowsStartupState.enabled,
          WindowsStartupState.enabledByPolicy,
        ]),
      );
    });

    test('isLockedByOther covers the states the app cannot change', () {
      expect(
        WindowsStartupState.values.where((s) => s.isLockedByOther),
        unorderedEquals([
          WindowsStartupState.disabledByUser,
          WindowsStartupState.disabledByPolicy,
          WindowsStartupState.enabledByPolicy,
        ]),
      );
    });
  });
}
