import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/auto_start_service.dart';
import 'package:ghostcopy/services/windows_package_service.dart';

/// Stands in for the runner. Records the calls so a test can prove
/// launch_at_startup was bypassed: if the packaged path were not taken,
/// AutoStartService would reach for PackageInfo and the Run key instead, and
/// none of these would be called.
class _FakePackage implements IWindowsPackageService {
  _FakePackage({
    required this.packaged,
    this.state = WindowsStartupState.disabled,
  });

  final bool packaged;
  WindowsStartupState state;
  final List<String> calls = [];

  @override
  Future<bool> isPackaged() async {
    calls.add('isPackaged');
    return packaged;
  }

  @override
  Future<WindowsStartupState> startupState() async {
    calls.add('startupState');
    return state;
  }

  @override
  Future<WindowsStartupState> enableStartup() async {
    calls.add('enableStartup');
    return state;
  }

  @override
  Future<WindowsStartupState> disableStartup() async {
    calls.add('disableStartup');
    return state;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AutoStartService> started(_FakePackage package) async {
    final service = AutoStartService(windowsPackageService: package);
    await service.initialize();
    return service;
  }

  test('a packaged build reads its state from the startup task', () async {
    final package = _FakePackage(
      packaged: true,
      state: WindowsStartupState.enabled,
    );
    final service = await started(package);

    expect(await service.isEnabled(), isTrue);
    expect(package.calls, ['isPackaged', 'startupState']);
  });

  test('enable and disable go to the startup task, not the Run key', () async {
    final package = _FakePackage(packaged: true);
    final service = await started(package);

    await service.enable();
    await service.disable();

    expect(package.calls, ['isPackaged', 'enableStartup', 'disableStartup']);
  });

  // Windows can report it on either while a policy or a Task Manager entry
  // holds it - isEnabled has to follow Windows, not what the app last asked.
  test('a policy-enabled task reads as on', () async {
    final package = _FakePackage(
      packaged: true,
      state: WindowsStartupState.enabledByPolicy,
    );
    final service = await started(package);
    expect(await service.isEnabled(), isTrue);
  });

  test('a user-disabled task reads as off after an enable request', () async {
    final package = _FakePackage(
      packaged: true,
      state: WindowsStartupState.disabledByUser,
    );
    final service = await started(package);

    await service.enable();
    expect(await service.isEnabled(), isFalse);
  });

  // Task Manager or a policy holds the entry: the settings toggle has to know
  // so it can say so, and startup must stop re-asking on every launch.
  test('a task held outside the app reports who holds it', () async {
    final package = _FakePackage(
      packaged: true,
      state: WindowsStartupState.disabledByUser,
    );
    final service = await started(package);
    expect(await service.lock(), AutoStartLock.disabledByUser);

    package.state = WindowsStartupState.disabledByPolicy;
    expect(await service.lock(), AutoStartLock.byPolicy);
    package.state = WindowsStartupState.enabledByPolicy;
    expect(await service.lock(), AutoStartLock.byPolicy);

    package.state = WindowsStartupState.disabled;
    expect(await service.lock(), AutoStartLock.none);
    package.state = WindowsStartupState.enabled;
    expect(await service.lock(), AutoStartLock.none);
  });

  test('dispose drops the packaged path', () async {
    final package = _FakePackage(packaged: true);
    final service = await started(package);
    service.dispose();

    expect(
      service.isEnabled(),
      throwsA(isA<StateError>()),
      reason: 'the service must be re-initialized before it answers again',
    );
  });
}
