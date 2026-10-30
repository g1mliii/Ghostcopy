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
