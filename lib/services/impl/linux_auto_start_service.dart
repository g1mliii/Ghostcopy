import 'dart:io';

import 'package:path/path.dart' as path;

import '../auto_start_service.dart';

/// XDG login startup with quoted paths and XDG_CONFIG_HOME support.
class LinuxAutoStartService implements IAutoStartService {
  LinuxAutoStartService({String? configDirectory, String? executable})
    : _entry = File(
        path.join(
          configDirectory ?? _configDirectory,
          'autostart',
          'ghostcopy.desktop',
        ),
      ),
      _executable = executable ?? Platform.resolvedExecutable;

  final File _entry;
  final String _executable;

  static String get _configDirectory {
    final override = Platform.environment['XDG_CONFIG_HOME'];
    if (override != null && path.isAbsolute(override)) return override;
    return path.join(Platform.environment['HOME']!, '.config');
  }

  /// Encode one Exec argument through both desktop-entry escaping layers.
  static String quoteExec(String value) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const FormatException('Executable path contains a newline');
    }
    final escaped = value.replaceAllMapped(
      RegExp(r'[\\"`$]'),
      (match) => '\\${match[0]}',
    );
    return '"${escaped.replaceAll(r'\', r'\\').replaceAll('%', '%%')}"';
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isEnabled() async =>
      _entry.existsSync() &&
      !_entry
          .readAsStringSync()
          .split('\n')
          .any((line) => line.trim() == 'Hidden=true');

  @override
  Future<void> enable() async {
    final contents =
        '[Desktop Entry]\nType=Application\nName=GhostCopy\n'
        'Exec=${quoteExec(_executable)} --launched-at-startup\n'
        'Terminal=false\nStartupNotify=false\n';
    _entry.parent.createSync(recursive: true);
    final temporary = File('${_entry.path}.tmp');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(_entry.path);
  }

  @override
  Future<void> disable() async {
    if (_entry.existsSync()) _entry.deleteSync();
  }

  @override
  Future<void> toggle() async {
    if (await isEnabled()) {
      await disable();
    } else {
      await enable();
    }
  }

  @override
  Future<AutoStartLock> lock() async => AutoStartLock.none;

  @override
  void dispose() {}
}
