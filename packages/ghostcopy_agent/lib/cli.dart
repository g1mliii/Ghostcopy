// The `ghostcopy` command. Pure Dart; see agent_protocol.dart for why it asks
// the running app rather than signing in itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'agent_protocol.dart';
import 'mcp_server.dart';

/// Exit codes, stable for scripts and agents.
abstract final class CliExit {
  static const int ok = 0;
  static const int usage = 1;

  /// GhostCopy is not installed, not running, or cannot accept the request.
  static const int unreachable = 2;

  /// GhostCopy answered no: command line access is off, nobody is signed in,
  /// or the request was invalid.
  static const int refused = 3;

  /// GhostCopy tried and the send failed - offline, rate limited.
  static const int failed = 4;

  /// The request reached GhostCopy but no answer came back - it timed out or
  /// the connection dropped - so it may have been sent. Not one to retry
  /// blindly: that is how a clip arrives twice.
  static const int unconfirmed = 5;

  static int of(AgentErrorKind kind) => switch (kind) {
    AgentErrorKind.usage => usage,
    AgentErrorKind.unreachable => unreachable,
    AgentErrorKind.refused => refused,
    AgentErrorKind.failed => failed,
    AgentErrorKind.unconfirmed => unconfirmed,
  };
}

const String cliUsage = '''
Send things to your other devices through GhostCopy.

Usage:
  ghostcopy send <text>        Send text or a link ("-" reads standard input;
                               "--" first if the text starts with a dash)
  ghostcopy send-file <path>   Send a file, up to 10 MB
  ghostcopy devices            List the devices on your account
  ghostcopy mcp                Run as an MCP server over standard input/output

Options:
  --to <devices>   Comma-separated: phone, desktop, ios, android, macos,
                   windows, linux. Default: the "Send to devices" setting.
  --json           Print machine-readable JSON.
  -h, --help       Show this help.

GhostCopy must be running, with "Command line & AI tools" turned on in its
settings. Exit codes: 0 sent, 1 usage, 2 GhostCopy unreachable, 3 refused,
4 send failed, 5 no answer after sending (check your history before retrying).''';

/// Run the command line. [stdinText] supplies `send -`.
Future<int> runCli(
  List<String> arguments, {
  AgentClient? client,
  StringSink? out,
  StringSink? err,
  Future<String?> Function()? stdinText,
  Stream<List<int>>? mcpInput,
  StringSink? mcpOutput,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final agent = client ?? AgentClient();

  // Known before parsing, so a usage error found before reaching it is
  // still reported the way --json promises.
  final dashDash = arguments.indexOf('--');
  final json = (dashDash == -1 ? arguments : arguments.take(dashDash)).contains(
    '--json',
  );

  /// A failure, in the form the caller asked for, and its exit code.
  /// [withUsage] adds the help text for a person; JSON is for a program.
  int fail(
    String message, {
    String code = AgentError.usage,
    bool withUsage = false,
  }) {
    if (json) {
      output.writeln(jsonEncode(agentErrorReply(code, message)));
    } else {
      errors.writeln(withUsage ? '$message\n\n$cliUsage' : message);
    }
    return CliExit.of(AgentError.kindOf(code));
  }

  final positional = <String>[];
  final to = <String>[];
  var endOfOptions = false;
  // Where `--` fell among the positionals: from here on each is literal
  // text, so `ghostcopy send -- -` sends a dash rather than reading stdin.
  var literalFrom = arguments.length;
  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    // After `--`, everything is text: `ghostcopy send -- --help` sends the
    // words "--help" rather than printing this.
    if (endOfOptions) {
      positional.add(arg);
    } else if (arg == '--') {
      endOfOptions = true;
      literalFrom = positional.length;
    } else if (arg == '-h' || arg == '--help') {
      output.writeln(cliUsage);
      return CliExit.ok;
    } else if (arg == '--json') {
      // Read above.
    } else if (arg == '--to') {
      if (i + 1 >= arguments.length) {
        return fail('--to needs a value, such as --to phone');
      }
      to.addAll(arguments[++i].split(','));
    } else if (arg.startsWith('--to=')) {
      to.addAll(arg.substring('--to='.length).split(','));
    } else if (arg.startsWith('--')) {
      return fail('Unknown option $arg', withUsage: true);
    } else {
      positional.add(arg);
    }
  }

  if (positional.isEmpty) {
    if (json) return fail('No command given.');
    output.writeln(cliUsage);
    return CliExit.usage;
  }

  final List<String> targets;
  try {
    targets = resolveDeviceTargets(to);
  } on FormatException catch (e) {
    return fail(e.message);
  }

  final command = positional.first;
  final rest = positional.skip(1).toList();
  final Map<String, Object?> request;
  switch (command) {
    case 'send':
      if (rest.isEmpty) {
        return fail('Nothing to send. Usage: ghostcopy send <text>');
      }
      final String? text;
      // rest starts at positional 1.
      if (rest.length == 1 && rest.single == '-' && literalFrom > 1) {
        // Not UTF-8 - a UTF-16 file from PowerShell's `>`, a legacy code page
        // - used to escape as an uncaught exception: no exit code a script
        // could read, and nothing at all under --json.
        try {
          text = await (stdinText ?? _readStdin)();
        } on FormatException {
          return fail(
            'Standard input is not UTF-8 text. Save it as UTF-8, or use '
            'send-file to send it as a file.',
          );
        } on IOException catch (e) {
          return fail('Could not read standard input: $e');
        }
      } else {
        text = rest.join(' ');
      }
      if (text == null || text.length > agentMaxTextLength) {
        return fail(
          'The text is too long to send: GhostCopy takes up to '
          '$agentMaxTextLength characters. Save it to a file and use '
          'send-file instead.',
        );
      }
      if (text.trim().isEmpty) {
        return fail('Nothing to send: the text is empty.');
      }
      request = {'name': AgentCommand.sendText, 'text': text, 'to': targets};
    case 'send-file':
      if (rest.length != 1) {
        return fail('Usage: ghostcopy send-file <path>');
      }
      // Absolute here: the app resolves paths from its own directory, not
      // from wherever this command was run.
      request = {
        'name': AgentCommand.sendFile,
        'path': File(rest.single).absolute.path,
        'to': targets,
      };
    case 'devices':
      request = {'name': AgentCommand.listDevices};
    case 'mcp':
      await McpServer(
        agent,
      ).serve(mcpInput ?? stdin, mcpOutput ?? stdout, log: errors);
      return CliExit.ok;
    default:
      return fail('Unknown command "$command".', withUsage: true);
  }

  final Map<String, Object?> reply;
  try {
    reply = await agent.request(request);
  } on AgentException catch (e) {
    return fail(e.message, code: e.code);
  }

  final ok = reply['ok'] == true;
  final message = reply['message'] as String? ?? (ok ? 'Done.' : 'Failed.');
  if (json) {
    output.writeln(jsonEncode(reply));
  } else if (ok && command == 'devices') {
    output.writeln(formatDevices(reply['devices']));
  } else {
    (ok ? output : errors).writeln(message);
  }
  return ok ? CliExit.ok : CliExit.of(AgentError.kindOf(reply['error']));
}

/// One device per line: name, type, and which one this is.
String formatDevices(Object? devices) {
  if (devices is! List || devices.isEmpty) return 'No devices on this account.';
  return devices
      .whereType<Map<String, Object?>>()
      .map((device) {
        final name = device['name'] ?? 'Unnamed device';
        final here = device['this_device'] == true ? '  (this computer)' : '';
        return '$name  [${device['type']}]$here';
      })
      .join('\n');
}

/// Standard input as text, or null once it is too long to send.
///
/// Stops reading there rather than buffering whatever was redirected in. A
/// UTF-16 code unit is at most three UTF-8 bytes, so more bytes than that
/// is more text than the limit, whatever it says.
Future<String?> _readStdin() async {
  const maxBytes = agentMaxTextLength * 3;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stdin) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) return null;
  }
  return utf8.decode(bytes.takeBytes());
}
