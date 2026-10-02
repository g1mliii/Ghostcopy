export 'impl/agent_command_handler.dart';

/// The outcome of sending a file at a path. [refusal] is set when the file
/// cannot be sent as it is - a folder, missing, too large - or nobody is
/// signed in: an `error` code for the command line, where a failed upload
/// leaves it null.
typedef SendFileResult = ({bool ok, String message, String? refusal});

/// Sends a file at a path, as Explorer's "Send with GhostCopy" and the macOS
/// service do. [targets] null means the user's default devices; empty means
/// every device.
typedef SendFileAtPath =
    Future<SendFileResult> Function(String path, List<String>? targets);

/// Answers the `ghostcopy` command line and its MCP server, which reach the
/// running app through SingleInstance. See packages/ghostcopy_agent.
// An interface like every other service, for mocking in tests.
// ignore: one_member_abstracts
abstract class IAgentCommandHandler {
  /// One command in, one answer out: `ok`, and on failure a stable `error`
  /// code and a `message` for a person.
  Future<Map<String, Object?>> handle(Map<String, Object?> command);
}
