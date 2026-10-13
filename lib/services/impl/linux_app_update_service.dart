import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
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

  /// How long the apply helper may take to stage a downloaded bundle.
  @visibleForTesting
  static const stagingTimeout = Duration(minutes: 10);

  /// When the feed was last asked, in milliseconds since the epoch.
  @visibleForTesting
  static const lastCheckPreference = 'linuxLastUpdateCheck';

  /// One check a day, counted across launches.
  @visibleForTesting
  static const checkInterval = Duration(hours: 24);
  DateTime? _lastCheck;
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
    final last = preferences.getInt(lastCheckPreference);
    _lastCheck = last == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(last);
    notifyListeners();
    _schedule();
    try {
      final error = await _takeReceiptError();
      if (error != null && !_disposed) {
        await showMessage('The update could not finish: $error');
      }
    } on Exception catch (error) {
      debugPrint('[LinuxUpdater] Could not read update receipt: $error');
    }
  }

  /// The detached helper's result, written by linux_update.py --apply.
  static File? get _receipt {
    final home = Platform.environment['HOME'];
    return home == null
        ? null
        : File('$home/.cache/ghostcopy/last-update.json');
  }

  /// The error the last apply reported, consuming its receipt.
  static Future<String?> _takeReceiptError() async {
    final receipt = _receipt;
    if (receipt == null || !receipt.existsSync()) return null;
    final data = jsonDecode(await receipt.readAsString());
    await receipt.delete();
    return data is Map<String, Object?> && data['error'] is String
        ? data['error']! as String
        : null;
  }

  /// Arm the next automatic check for a day after the last one, whichever
  /// launch made it. Autostart used to start python3 and fetch the feed at
  /// every login, however recently it had been asked.
  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!_automatic || !_available || _disposed) return;
    final last = _lastCheck;
    final wait = last == null
        ? Duration.zero
        : last.add(checkInterval).difference(clock.now());
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      unawaited(_backgroundCheck());
    });
  }

  Future<Map<String, Object?>> _run(List<String> arguments) async {
    final runner = runUpdater;
    if (runner != null) return runner(arguments);
    final process = await Process.start('python3', _updater(arguments));
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

  List<String> _updater(List<String> arguments) => [
    '$_directory/linux_update.py',
    ...arguments,
  ];

  /// Ask the feed, and redraw only when the answer changed. The attempt is
  /// recorded before it runs, so a failure is not retried until the next
  /// interval and a manual check also counts as the day's check.
  Future<Map<String, Object?>> _check() async {
    final now = clock.now();
    _lastCheck = now;
    // Re-arm from this check, so a manual one also moves the automatic
    // deadline rather than leaving the old timer to check again within a day.
    _schedule();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(lastCheckPreference, now.millisecondsSinceEpoch);
    final result = await _run(['--check']);
    final available = result['available'] == true;
    if (!_disposed && available != _updateAvailable) {
      _updateAvailable = available;
      notifyListeners();
    }
    return result;
  }

  Future<void> _backgroundCheck() async {
    if (_disposed) return;
    // A manual check already in flight has recorded itself as today's.
    if (!_busy) {
      _busy = true;
      try {
        await _check();
      } on Exception catch (error) {
        debugPrint('[LinuxUpdater] Background check unavailable: $error');
      } finally {
        _busy = false;
      }
    }
    _schedule();
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
      final result = await _check();
      if (_disposed) return;
      if (!_updateAvailable) {
        await showMessage('GhostCopy ${result['current']} is up to date.');
        return;
      }
      final version = result['version']! as String;
      if (!await confirmInstall(version) || _disposed) return;
      showDownloading();
      final prepared = await _run(['--prepare', version]);
      final directory = prepared['directory']! as String;
      if (_disposed) {
        // Quit during the download: nothing will apply it now, and each
        // abandoned one is up to the archive size limit.
        await Directory(directory).delete(recursive: true);
        return;
      }
      // A failure left over from an earlier attempt must not read as this one's.
      await _takeReceiptError();
      await Process.start(
        'python3',
        _updater(['--apply', directory, '--wait-pid', '$pid', '--restart']),
        mode: ProcessStartMode.detached,
      );
      // The helper extracts and validates the whole bundle - up to 1 GiB -
      // before signalling that we can quit, so the wait covers staging, and
      // ends early when the helper reports that it failed.
      final ready = File('$directory/ready');
      final deadline = DateTime.now().add(stagingTimeout);
      while (!ready.existsSync()) {
        if (_disposed) return;
        final error = await _takeReceiptError();
        if (error != null) throw FormatException(error);
        if (DateTime.now().isAfter(deadline)) {
          throw const FormatException(
            'The updater did not finish preparing. GhostCopy has stayed open.',
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
    // A check is due at once only if the last one was a day ago or more.
    _schedule();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
