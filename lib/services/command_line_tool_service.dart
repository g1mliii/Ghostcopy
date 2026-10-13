export 'impl/command_line_tool_service.dart';

/// Whether the `ghostcopy` command can be typed in a terminal.
enum CommandLineToolState {
  /// This build carries no command to install.
  unavailable,

  /// Bundled, but nothing on the PATH points at it.
  notInstalled,

  /// The PATH entry points at this copy of the app.
  installed,
}

/// Puts the bundled `ghostcopy` command on the PATH (macOS).
///
/// Windows registers an execution alias from the MSIX manifest and the Linux
/// installer writes a wrapper into `~/.local/bin`, so neither needs a button.
/// On macOS the command ships inside the app at `Contents/Helpers/ghostcopy`,
/// and no directory on the default PATH is writable without a password, so the
/// link into `/usr/local/bin` is made on request - the way editors install
/// their own command.
abstract class ICommandLineToolService {
  Future<CommandLineToolState> state();

  /// Asks for an administrator password and links the command into the PATH.
  /// False when the user cancels the prompt or the link fails.
  Future<bool> install();
}
