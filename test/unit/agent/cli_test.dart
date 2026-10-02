import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';
import 'package:ghostcopy_agent/cli.dart';

import 'agent_test_support.dart';

void main() {
  late FakeAgentClient client;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    client = FakeAgentClient();
    out = StringBuffer();
    err = StringBuffer();
  });

  Future<int> run(List<String> args, {String stdinText = ''}) => runCli(
    args,
    client: client,
    out: out,
    err: err,
    stdinText: () async => stdinText,
  );

  test('send joins the words and asks for the default devices', () async {
    client.reply = (_) => {'ok': true, 'message': 'Sent to all your devices.'};

    expect(await run(['send', 'hello', 'world']), CliExit.ok);

    expect(client.requests.single, {
      'name': 'send_text',
      'text': 'hello world',
      'to': <String>[],
    });
    expect(out.toString(), contains('Sent to all your devices.'));
  });

  test('--to phone resolves before it is sent', () async {
    await run(['send', 'hi', '--to', 'phone']);
    expect(client.requests.single['to'], ['android', 'ios']);

    await run(['send', 'hi', '--to=mac,pc']);
    expect(client.requests.last['to'], ['macos', 'windows']);
  });

  test('send - reads standard input', () async {
    await run(['send', '-'], stdinText: 'piped in\n');
    expect(client.requests.single['text'], 'piped in\n');
  });

  test('send-file sends an absolute path', () async {
    await run(['send-file', 'notes.txt']);
    expect(client.requests.single['path'], File('notes.txt').absolute.path);
  });

  test('devices prints one per line, marking this computer', () async {
    client.reply = (_) => {
      'ok': true,
      'devices': [
        {'name': 'Pixel', 'type': 'android', 'this_device': false},
        {'name': 'Desk', 'type': 'windows', 'this_device': true},
      ],
    };

    await run(['devices']);

    expect(
      out.toString(),
      'Pixel  [android]\nDesk  [windows]  (this computer)\n',
    );
  });

  test('--json prints the app answer as it is', () async {
    client.reply = (_) => {'ok': true, 'status': 'sent', 'message': 'Sent.'};
    await run(['send', 'x', '--json']);
    expect(jsonDecode(out.toString()), {
      'ok': true,
      'status': 'sent',
      'message': 'Sent.',
    });
  });

  test('-- sends what follows as text, options and all', () async {
    expect(await run(['send', '--', '--help', 'me']), CliExit.ok);
    expect(client.requests.single['text'], '--help me');
  });

  group('exit codes', () {
    test('GhostCopy not running is 2, with the reason', () async {
      client.error = const AgentException('not_running', 'Open GhostCopy.');
      expect(await run(['send', 'x']), CliExit.unreachable);
      expect(err.toString(), contains('Open GhostCopy.'));
    });

    test('a refusal is 3', () async {
      client.reply = (_) => {
        'ok': false,
        'error': 'disabled',
        'message': 'Turned off.',
      };
      expect(await run(['send', 'x']), CliExit.refused);
      expect(err.toString(), contains('Turned off.'));
    });

    test('still starting is 2, worth retrying, not a refusal', () async {
      client.reply = (_) => {
        'ok': false,
        'error': 'not_ready',
        'message': 'GhostCopy is still starting.',
      };
      expect(await run(['send', 'x']), CliExit.unreachable);
    });

    test('a failed send is 4', () async {
      client.reply = (_) => {
        'ok': false,
        'error': 'send_failed',
        'message': 'Offline.',
      };
      expect(await run(['send', 'x']), CliExit.failed);
    });

    test('usage mistakes are 1 and send nothing', () async {
      expect(await run(['send']), CliExit.usage);
      expect(await run(['send', '   ']), CliExit.usage);
      expect(await run(['send', 'x', '--to', 'toaster']), CliExit.usage);
      expect(await run(['launch-rockets']), CliExit.usage);
      expect(await run(['send', 'x', '--loud']), CliExit.usage);
      expect(client.requests, isEmpty);
    });

    test('help is 0', () async {
      expect(await run(['--help']), CliExit.ok);
      expect(out.toString(), contains('ghostcopy send <text>'));
    });
  });
}
