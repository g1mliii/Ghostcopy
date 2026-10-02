// The `ghostcopy` command line and MCP server. Compile with
//   cd packages/ghostcopy_agent && dart pub get
//   dart compile exe bin/ghostcopy.dart -o ghostcopy
// It talks to the GhostCopy app running on this computer; see
// lib/agent_protocol.dart in this package.

import 'dart:io';

import 'package:ghostcopy_agent/cli.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  // Both: every failure explains itself on stderr, and exit() does not wait
  // for a sink still writing to a pipe or a file.
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}
