import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/impl/linux_app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory installation;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'linuxAutomaticUpdateChecks': false,
    });
    installation = Directory.systemTemp.createTempSync(
      'ghostcopy-update-test-',
    );
    for (final name in [
      'install-manifest.json',
      'linux_update.py',
      'linux-version.json',
    ]) {
      File('${installation.path}/$name').writeAsStringSync('{}');
    }
  });

  tearDown(() => installation.deleteSync(recursive: true));

  test(
    'declining update does not download or quit and keeps availability',
    () async {
      final commands = <List<String>>[];
      final service = LinuxAppUpdateService(
        executableDirectory: installation.path,
        runUpdater: (arguments) async {
          commands.add(arguments);
          return {'available': true, 'version': '1.0.9+22'};
        },
        confirmInstall: (version) async {
          expect(version, '1.0.9+22');
          return false;
        },
        showMessage: (_) async => fail('Unexpected message'),
        showDownloading: () => fail('Must not download'),
        quit: () async => fail('Must not quit'),
      );
      addTearDown(service.dispose);
      await service.initialize();
      expect(service.automaticChecks, isFalse);
      await service.checkForUpdates();
      expect(service.updateAvailable, isTrue);
      expect(commands, [
        ['--check'],
      ]);
    },
  );

  test(
    'download failure leaves the app running and surfaces the error',
    () async {
      final service = LinuxAppUpdateService(
        executableDirectory: installation.path,
        runUpdater: (arguments) async {
          if (arguments.first == '--prepare') {
            throw const FormatException('Checksum mismatch');
          }
          return {'available': true, 'version': '1.0.9+22'};
        },
        confirmInstall: (_) async => true,
        showMessage: (_) async {},
        showDownloading: () {},
        quit: () async => fail('Must not quit on download failure'),
      );
      addTearDown(service.dispose);
      await service.initialize();
      await expectLater(
        service.checkForUpdates(),
        throwsA(isA<PlatformException>()),
      );
    },
  );

  test('uninstalled source builds do not offer automatic updates', () async {
    File('${installation.path}/install-manifest.json').deleteSync();
    final service = LinuxAppUpdateService(
      executableDirectory: installation.path,
      runUpdater: (_) async => throw const FormatException('Must not run'),
      confirmInstall: (_) async => false,
      showMessage: (_) async {},
      showDownloading: () {},
      quit: () async {},
    );
    addTearDown(service.dispose);
    await service.initialize();
    expect(service.isAvailable, isFalse);
    await expectLater(
      service.checkForUpdates(),
      throwsA(isA<PlatformException>()),
    );
  });
}
