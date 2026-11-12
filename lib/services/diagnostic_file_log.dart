import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A small log file for release builds on the desktop, of how clips reach
/// the app: realtime, desktop push, the tray poll, the lifecycle switching
/// between them.
///
/// Release builds silence debugPrint (see main.dart), so on a Store or
/// Developer ID build there was no way to see why a clip did or did not
/// arrive except by watching network connections from outside. This keeps
/// only lines from the sync and push services - which log ids, counts and
/// states, never clip content - with a timestamp, in
/// `<app support>/logs/ghostcopy.log`. A packaged Windows build's app support
/// folder is the package's own, which Windows deletes with it.
///
/// Bounded: once the file passes [maxBytes] it is renamed to
/// `ghostcopy.1.log` on the next launch, and nothing more is written in a
/// session that reaches twice that.
class DiagnosticFileLog {
  DiagnosticFileLog._();

  static const int maxBytes = 512 * 1024;

  /// Lines kept. Everything else debugPrint is given in release is dropped,
  /// as it was before this existed.
  static const List<String> _prefixes = [
    '[ClipboardSync',
    '[DesktopPush]',
    '[Lifecycle]',
    '[MacPush]',
    '[WindowsPush]',
  ];

  static IOSink? _sink;
  static int _written = 0;
  static final List<String> _early = [];

  /// Open the file. Lines logged before it is open are kept and written
  /// once it is.
  static Future<void> open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'logs'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'ghostcopy.log'));
      // Sync calls: a few stat calls once per launch, off any hot path.
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        final previous = File(p.join(dir.path, 'ghostcopy.1.log'));
        if (previous.existsSync()) previous.deleteSync();
        file.renameSync(previous.path);
      }
      // Lives as long as the app; the OS closes it on exit.
      // ignore: close_sinks
      final sink = File(file.path).openWrite(mode: FileMode.append)
        ..writeln('${_now()} --- launch (pid $pid) ---');
      _sink = sink;
      _early
        ..forEach(_write)
        ..clear();
    } on Object {
      // A log that cannot be opened must not stop the app.
      _early.clear();
    }
  }

  /// A debugPrint replacement for release builds.
  static void print(String? message, {int? wrapWidth}) {
    if (message == null || !_prefixes.any(message.startsWith)) return;
    final line = '${_now()} $message';
    if (_sink == null) {
      if (_early.length < 200) _early.add(line);
      return;
    }
    _write(line);
  }

  static void _write(String line) {
    if (_written > maxBytes * 2) return;
    _written += line.length + 1;
    _sink?.writeln(line);
  }

  static String _now() => DateTime.now().toIso8601String();
}
