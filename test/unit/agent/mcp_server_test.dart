import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';
import 'package:ghostcopy_agent/mcp_server.dart';

import 'agent_test_support.dart';

void main() {
  late FakeAgentClient client;
  late McpServer server;

  setUp(() {
    client = FakeAgentClient();
    server = McpServer(client);
  });

  Future<Map<String, Object?>?> call(Map<String, Object?> message) =>
      server.handleLine(jsonEncode(message));

  test('initialize agrees a protocol version the client asked for', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-03-26'},
    });
    final result = reply!['result']! as Map<String, Object?>;
    expect(result['protocolVersion'], '2025-03-26');
    expect((result['serverInfo']! as Map)['name'], 'ghostcopy');
  });

  test('an unknown protocol version gets the newest', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {'protocolVersion': '1999-01-01'},
    });
    expect(
      (reply!['result']! as Map)['protocolVersion'],
      mcpProtocolVersions.first,
    );
  });

  test('tools/list names the three tools', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    });
    final tools = (reply!['result']! as Map)['tools']! as List;
    expect(tools.map((t) => (t as Map)['name']), [
      'send_text',
      'send_file',
      'list_devices',
    ]);
  });

  test('send_text goes to the app, with "phone" resolved', () async {
    client.reply = (_) => {'ok': true, 'message': 'Sent to iPhone.'};

    final reply = await call({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'send_text',
        'arguments': {
          'text': 'https://example.com',
          'to': ['phone'],
        },
      },
    });

    expect(client.requests.single, {
      'name': 'send_text',
      'text': 'https://example.com',
      'to': ['android', 'ios'],
    });
    final result = reply!['result']! as Map;
    expect(result['isError'], isNull);
    expect(
      ((result['content']! as List).single as Map)['text'],
      'Sent to iPhone.',
    );
  });

  test('a refusal is a tool error the assistant can read', () async {
    client.reply = (_) => {
      'ok': false,
      'error': 'disabled',
      'message': 'Turn on "Command line & AI tools".',
    };

    final reply = await call({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {
        'name': 'send_text',
        'arguments': {'text': 'hi'},
      },
    });

    final result = reply!['result']! as Map;
    expect(result['isError'], isTrue);
    expect(
      ((result['content']! as List).single as Map)['text'],
      contains('Command line & AI tools'),
    );
  });

  test('GhostCopy not running is a tool error too', () async {
    client.error = const AgentException('not_running', 'Open GhostCopy.');
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'tools/call',
      'params': {'name': 'list_devices', 'arguments': <String, Object?>{}},
    });
    expect((reply!['result']! as Map)['isError'], isTrue);
  });

  test('empty text never reaches the app', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'tools/call',
      'params': {
        'name': 'send_text',
        'arguments': {'text': '  '},
      },
    });
    expect((reply!['result']! as Map)['isError'], isTrue);
    expect(client.requests, isEmpty);
  });

  test('notifications get no reply; unknown methods an error', () async {
    expect(
      await call({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      isNull,
    );
    final reply = await call({'jsonrpc': '2.0', 'id': 7, 'method': 'nope'});
    expect((reply!['error']! as Map)['code'], -32601);
  });

  test('a line that is not JSON is a parse error', () async {
    final reply = await server.handleLine('{not json');
    expect((reply!['error']! as Map)['code'], -32700);
  });

  test('serve answers line by line on stdout and nothing else', () async {
    final input = StreamController<List<int>>();
    final output = StringBuffer();
    final serving = server.serve(input.stream, output);
    input
      ..add(utf8.encode('{"jsonrpc":"2.0","id":1,"method":"ping"}\n'))
      ..add(utf8.encode('{"jsonrpc":"2.0","method":"notifications/x"}\n'));
    await input.close();
    await serving;

    final lines = const LineSplitter().convert(output.toString());
    expect(lines, hasLength(1));
    expect(jsonDecode(lines.single), {
      'jsonrpc': '2.0',
      'id': 1,
      'result': <String, Object?>{},
    });
  });
}
