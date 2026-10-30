import 'dart:io';

import 'package:path/path.dart' as path;

/// The XDG config directory: XDG_CONFIG_HOME when it is an absolute path, as
/// the spec requires, otherwise ~/.config.
String xdgConfigHome() {
  final override = Platform.environment['XDG_CONFIG_HOME'];
  if (override != null && path.isAbsolute(override)) return override;
  return path.join(Platform.environment['HOME']!, '.config');
}

/// The XDG data directories in lookup order: XDG_DATA_HOME (or
/// ~/.local/share), then XDG_DATA_DIRS (or /usr/local/share and /usr/share).
/// Relative entries are skipped, as the spec requires. Flatpak's exports are
/// on XDG_DATA_DIRS wherever Flatpak is installed, so they come along.
List<String> xdgDataDirs([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['XDG_DATA_HOME'];
  final dirs = env['XDG_DATA_DIRS'];
  return [
    if (home != null && path.isAbsolute(home))
      home
    else if (env['HOME'] case final userHome?)
      path.join(userHome, '.local', 'share'),
    ...(dirs == null || dirs.isEmpty ? '/usr/local/share:/usr/share' : dirs)
        .split(':')
        .where(path.isAbsolute),
  ];
}

/// The unlocalised keys of a desktop entry's `[Desktop Entry]` group.
Map<String, String> parseDesktopEntry(String contents) {
  final keys = <String, String>{};
  var inEntry = false;
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inEntry = line == '[Desktop Entry]';
      continue;
    }
    if (!inEntry || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    final key = line.substring(0, equals).trim();
    // Name[fr] and the like: the plain key is what every entry has.
    if (key.contains('[')) continue;
    keys.putIfAbsent(key, () => line.substring(equals + 1).trim());
  }
  return keys;
}
