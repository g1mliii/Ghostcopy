import 'dart:io';

import 'package:path/path.dart' as path;

/// The XDG config directory: XDG_CONFIG_HOME when it is an absolute path, as
/// the spec requires, otherwise ~/.config.
String xdgConfigHome() {
  final override = Platform.environment['XDG_CONFIG_HOME'];
  if (override != null && path.isAbsolute(override)) return override;
  return path.join(Platform.environment['HOME']!, '.config');
}
