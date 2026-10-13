import 'dart:io';

import 'package:flutter/foundation.dart';

import '../command_line_tool_service.dart';

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class CommandLineToolService implements ICommandLineToolService {
  CommandLineToolService({
    String? helperPath,
    this.linkPath = '/usr/local/bin/ghostcopy',
    ProcessRunner? runProcess,
  }) : helperPath = helperPath ?? _bundledHelper(),
       _runProcess = runProcess ?? Process.run;

  /// The command inside this app, beside `Contents/MacOS` in `Contents/Helpers`.
  final String helperPath;

  /// `/usr/local/bin` is in macOS's default `/etc/paths`, and a symlink there
  /// keeps pointing at the app across Sparkle updates, which replace the
  /// bundle at the same path.
  final String linkPath;

  final ProcessRunner _runProcess;

  static String _bundledHelper() => File(
    Platform.resolvedExecutable,
  ).parent.parent.uri.resolve('Helpers/ghostcopy').toFilePath();

  @override
  Future<CommandLineToolState> state() async {
    if (!File(helperPath).existsSync()) return CommandLineToolState.unavailable;
    final link = Link(linkPath);
    // A file of the same name that is not our link - a hand-built companion
    // from before it was bundled - counts as not installed. Installing then
    // replaces it, which is the point.
    if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
        FileSystemEntityType.link) {
      return CommandLineToolState.notInstalled;
    }
    return link.targetSync() == helperPath
        ? CommandLineToolState.installed
        : CommandLineToolState.notInstalled;
  }

  @override
  Future<bool> install() async {
    // The paths go in as arguments and through `quoted form of`, never spliced
    // into the script, so an app path with quotes or spaces cannot change what
    // runs as root.
    final result = await _runProcess('/usr/bin/osascript', [
      '-e',
      'on run argv',
      '-e',
      'set {helperPath, linkPath, linkDir} to argv',
      '-e',
      'do shell script "mkdir -p " & quoted form of linkDir & " && ln -sfn " & '
          'quoted form of helperPath & " " & quoted form of linkPath '
          'with administrator privileges',
      '-e',
      'end run',
      helperPath,
      linkPath,
      File(linkPath).parent.path,
    ]);
    if (result.exitCode != 0) {
      // -128 is the user cancelling the password prompt.
      debugPrint('[CommandLineTool] Install failed: ${result.stderr}');
      return false;
    }
    return await state() == CommandLineToolState.installed;
  }
}
