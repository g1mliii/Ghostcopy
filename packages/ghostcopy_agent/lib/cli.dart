// The `ghostcopy` command. Pure Dart; see agent_protocol.dart for why it asks
// the running app rather than signing in itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_protocol.dart';
import 'mcp_server.dart';

/// Exit codes, stable for scripts and agents.
abstract final class CliExit {
  static const int ok = 0;
  static const int usage = 1;

  /// GhostCopy is not installed, not running, or did not answer.
  static const int unreachable = 2;

  /// GhostCopy answered no: command line access is off, nobody is signed in,
  /// or the request was invalid.
  static const int refused = 3;

  /// GhostCopy tried and the send failed - offline, too large, rate limited.
  static const int failed = 4;
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
4 send failed.''';

/// Run the command line. [stdinText] supplies `send -`.
Future<int> runCli(
  List<String> arguments, {
  AgentClient? client,
  StringSink? out,
  StringSink? err,
  Future<String> Function()? stdinText,
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

  /// A usage mistake, in the form the caller asked for.
  int fail(String message) {
    if (json) {
      output.writeln(
        jsonEncode({'ok': false, 'error': 'usage', 'message': message}),
      );
    } else {
      errors.writeln(message);
    }
    return CliExit.usage;
  }

  final positional = <String>[];
  final to = <String>[];
  var endOfOptions = false;
  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    // After `--`, everything is text: `ghostcopy send -- --help` sends the
    // words "--help" rather than printing this.
    if (endOfOptions) {
      positional.add(arg);
    } else if (arg == '--') {
      endOfOptions = true;
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
      return fail(
        json ? 'Unknown option $arg' : 'Unknown option $arg\n\n$cliUsage',
      );
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
      final text = rest.length == 1 && rest.single == '-'
          ? await (stdinText ?? _readStdin)()
          : rest.join(' ');
      if (text.trim().isEmpty) {
        return fail('Nothing to send: the text is empty.');
      }
      request = {'name': 'send_text', 'text': text, 'to': targets};
    case 'send-file':
      if (rest.length != 1) {
        return fail('Usage: ghostcopy send-file <path>');
      }
      // Absolute here: the app resolves paths from its own directory, not
      // from wherever this command was run.
      request = {
        'name': 'send_file',
        'path': File(rest.single).absolute.path,
        'to': targets,
      };
    case 'devices':
      request = {'name': 'list_devices'};
    case 'mcp':
      await McpServer(
        agent,
      ).serve(mcpInput ?? stdin, mcpOutput ?? stdout, log: errors);
      return CliExit.ok;
    default:
      return fail(
        json
            ? 'Unknown command "$command".'
            : 'Unknown command "$command".\n\n$cliUsage',
      );
  }

  final Map<String, Object?> reply;
  try {
    reply = await agent.request(request);
  } on AgentException catch (e) {
    _report(
      output,
      errors,
      json: json,
      ok: false,
      code: e.code,
      message: e.message,
    );
    return CliExit.unreachable;
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
  if (ok) return CliExit.ok;
  return switch (reply['error']) {
    'send_failed' => CliExit.failed,
    // Still starting up: try again shortly, not a refusal to give up on.
    'not_ready' => CliExit.unreachable,
    _ => CliExit.refused,
  };
}

void _report(
  StringSink output,
  StringSink errors, {
  required bool json,
  required bool ok,
  required String code,
  required String message,
}) {
  if (json) {
    output.writeln(jsonEncode({'ok': ok, 'error': code, 'message': message}));
  } else {
    errors.writeln(message);
  }
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

Future<String> _readStdin() => utf8.decoder.bind(stdin).join();
