import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
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

  test('quitting during the download deletes what it downloaded', () async {
    final download = Directory('${installation.path}/download-test')
      ..createSync();
    File('${download.path}/update.tar.gz').writeAsStringSync('archive');
    late LinuxAppUpdateService service;
    service = LinuxAppUpdateService(
      executableDirectory: installation.path,
      runUpdater: (arguments) async {
        if (arguments.first == '--prepare') {
          service.dispose(); // GhostCopy quit while this ran.
          return {'directory': download.path, 'version': '1.0.9+22'};
        }
        return {'available': true, 'version': '1.0.9+22'};
      },
      confirmInstall: (_) async => true,
      showMessage: (_) async {},
      showDownloading: () {},
      quit: () async => fail('Already quitting'),
    );
    await service.initialize();
    await service.checkForUpdates();
    expect(download.existsSync(), isFalse);
  });

  group('automatic checks', () {
    final start = DateTime(2026, 10, 13, 9);

    LinuxAppUpdateService service(List<List<String>> commands) =>
        LinuxAppUpdateService(
          executableDirectory: installation.path,
          runUpdater: (arguments) async {
            commands.add(arguments);
            return {'available': false, 'current': '1.0.9+25'};
          },
          confirmInstall: (_) async => false,
          showMessage: (_) async {},
          showDownloading: () {},
          quit: () async {},
        );

    test('a launch within a day of the last check does not check', () {
      SharedPreferences.setMockInitialValues({
        LinuxAppUpdateService.lastCheckPreference: start
            .subtract(const Duration(hours: 23))
            .millisecondsSinceEpoch,
      });
      fakeAsync((async) {
        withClock(async.getClock(start), () {
          final commands = <List<String>>[];
          final updater = service(commands);
          unawaited(updater.initialize());
          async.elapse(const Duration(minutes: 59));
          expect(commands, isEmpty);
          // Due a day after the previous launch's check, not this one's.
          async.elapse(const Duration(minutes: 2));
          expect(commands, [
            ['--check'],
          ]);
          // And then once a day.
          async.elapse(LinuxAppUpdateService.checkInterval);
          expect(commands, hasLength(2));
          updater.dispose();
        });
      });
    });

    test('a manual check moves the automatic one a day on', () {
      SharedPreferences.setMockInitialValues({
        LinuxAppUpdateService.lastCheckPreference: start
            .subtract(const Duration(hours: 23))
            .millisecondsSinceEpoch,
      });
      fakeAsync((async) {
        withClock(async.getClock(start), () {
          final commands = <List<String>>[];
          final updater = service(commands);
          unawaited(updater.initialize());
          async.elapse(const Duration(minutes: 30));
          unawaited(updater.checkForUpdates());
          async.flushMicrotasks();
          expect(commands, hasLength(1));
          // The old deadline, an hour after launch, no longer checks.
          async.elapse(const Duration(hours: 2));
          expect(commands, hasLength(1));
          // A day after the manual check, it does.
          async.elapse(const Duration(hours: 22, minutes: 31));
          expect(commands, hasLength(2));
          updater.dispose();
        });
      });
    });

    test('a dialog left open past the deadline does not spin', () {
      SharedPreferences.setMockInitialValues({});
      fakeAsync((async) {
        withClock(async.getClock(start), () {
          final commands = <List<String>>[];
          final confirm = Completer<bool>();
          final updater = LinuxAppUpdateService(
            executableDirectory: installation.path,
            runUpdater: (arguments) async {
              commands.add(arguments);
              return {'available': true, 'version': '1.0.9+26'};
            },
            confirmInstall: (_) => confirm.future,
            showMessage: (_) async {},
            showDownloading: () {},
            quit: () async {},
          );
          unawaited(updater.initialize());
          async.elapse(Duration.zero);
          unawaited(updater.checkForUpdates());
          async.flushMicrotasks();
          // Overdue while busy: a zero-delay re-arm would never let this
          // elapse finish.
          async.elapse(const Duration(hours: 30));
          expect(commands, hasLength(2));
          confirm.complete(false);
          async.elapse(Duration.zero);
          // The skipped automatic check runs once the dialog closes.
          expect(commands, hasLength(3));
          updater.dispose();
        });
      });
    });

    test('a first launch checks at once and records it', () {
      SharedPreferences.setMockInitialValues({});
      fakeAsync((async) {
        withClock(async.getClock(start), () {
          final commands = <List<String>>[];
          final updater = service(commands);
          unawaited(updater.initialize());
          async
            ..flushMicrotasks()
            ..elapse(Duration.zero);
          expect(commands, [
            ['--check'],
          ]);
          late SharedPreferences preferences;
          unawaited(
            SharedPreferences.getInstance().then((p) => preferences = p),
          );
          async.flushMicrotasks();
          expect(
            preferences.getInt(LinuxAppUpdateService.lastCheckPreference),
            start.millisecondsSinceEpoch,
          );
          updater.dispose();
        });
      });
    });
  });

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
