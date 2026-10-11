import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_update_service.dart';

/// Checks the Linux release feed and hands installation to a separate process.
class LinuxAppUpdateService extends IAppUpdateService {
  LinuxAppUpdateService({
    required this.confirmInstall,
    required this.showMessage,
    required this.showDownloading,
    required this.quit,
    String? executableDirectory,
    this.runUpdater,
  }) : _directory =
           executableDirectory ?? File(Platform.resolvedExecutable).parent.path;

  final Future<bool> Function(String version) confirmInstall;
  final Future<void> Function(String message) showMessage;
  final VoidCallback showDownloading;
  final Future<void> Function() quit;
  final String _directory;

  /// Optional protocol runner for testing without launching an updater process.
  final Future<Map<String, Object?>> Function(List<String> arguments)?
  runUpdater;
  static const _preference = 'linuxAutomaticUpdateChecks';
  bool _available = false;
  bool _automatic = true;
  bool _updateAvailable = false;
  bool _disposed = false;
  bool _busy = false;
  Timer? _timer;

  @override
  bool get isAvailable => _available;
  @override
  bool get automaticChecks => _automatic;
  @override
  bool get updateAvailable => _updateAvailable;

  @override
  Future<void> initialize() async {
    _available =
        File('$_directory/install-manifest.json').existsSync() &&
        File('$_directory/linux_update.py').existsSync() &&
        File('$_directory/linux-version.json').existsSync();
    final preferences = await SharedPreferences.getInstance();
    if (_disposed) return;
    _automatic = preferences.getBool(_preference) ?? true;
    notifyListeners();
    _schedule();
    if (_automatic && _available) unawaited(_backgroundCheck());
    final home = Platform.environment['HOME'];
    if (home != null) {
      final receipt = File('$home/.cache/ghostcopy/last-update.json');
      if (receipt.existsSync()) {
        try {
          final data = jsonDecode(await receipt.readAsString());
          await receipt.delete();
          if (!_disposed &&
              data is Map<String, Object?> &&
              data['error'] is String) {
            await showMessage('The update could not finish: ${data['error']}');
          }
        } on Exception catch (error) {
          debugPrint('[LinuxUpdater] Could not read update receipt: $error');
        }
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_automatic && _available && !_disposed) {
      _timer = Timer.periodic(const Duration(hours: 24), (_) {
        unawaited(_backgroundCheck());
      });
    }
  }

  Future<Map<String, Object?>> _run(List<String> arguments) async {
    final runner = runUpdater;
    if (runner != null) return runner(arguments);
    final process = await Process.start('python3', [
      '$_directory/linux_update.py',
      ...arguments,
    ]);
    try {
      final outputs = await Future.wait<Object>([
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.transform(utf8.decoder).join(),
        process.exitCode,
      ]).timeout(const Duration(minutes: 5));
      if (outputs[2] != 0) {
        throw PlatformException(
          code: 'linux_update_failed',
          message: (outputs[1] as String).trim(),
        );
      }
      final result = jsonDecode(outputs[0] as String);
      if (result is! Map<String, Object?>) {
        throw const FormatException('Invalid updater response');
      }
      return result;
    } finally {
      process.kill();
    }
  }

  Future<void> _backgroundCheck() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final result = await _run(['--check']);
      if (!_disposed) {
        _updateAvailable = result['available'] == true;
        notifyListeners();
      }
    } on Exception catch (error) {
      debugPrint('[LinuxUpdater] Background check unavailable: $error');
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> checkForUpdates() async {
    if (_disposed) return;
    if (_busy) {
      await showMessage('An update check or download is already in progress.');
      return;
    }
    if (!_available) {
      throw PlatformException(
        code: 'linux_updater_unavailable',
        message:
            'Install this Linux build with install_linux.py to enable updates.',
      );
    }
    _busy = true;
    try {
      final result = await _run(['--check']);
      if (_disposed) return;
      _updateAvailable = result['available'] == true;
      notifyListeners();
      if (!_updateAvailable) {
        await showMessage('GhostCopy ${result['current']} is up to date.');
        return;
      }
      final version = result['version']! as String;
      if (!await confirmInstall(version) || _disposed) return;
      showDownloading();
      final prepared = await _run(['--prepare', version]);
      if (_disposed) return;
      final directory = prepared['directory']! as String;
      await Process.start('python3', [
        '$_directory/linux_update.py',
        '--apply',
        directory,
        '--wait-pid',
        '$pid',
        '--restart',
      ], mode: ProcessStartMode.detached);
      // The helper validates and stages before signalling that we can quit.
      final ready = File('$directory/ready');
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!ready.existsSync()) {
        if (_disposed) return;
        if (DateTime.now().isAfter(deadline)) {
          throw const FormatException(
            'The updater did not start. GhostCopy has stayed open.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await quit();
    } on PlatformException {
      rethrow;
    } on Exception catch (error) {
      throw PlatformException(code: 'linux_update_failed', message: '$error');
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> setAutomaticChecks({required bool enabled}) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_preference, enabled)) {
      throw PlatformException(
        code: 'linux_update_preferences',
        message: 'Could not save update preferences.',
      );
    }
    if (_disposed) return;
    _automatic = enabled;
    _schedule();
    notifyListeners();
    if (enabled) unawaited(_backgroundCheck());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
