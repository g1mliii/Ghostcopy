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

  // A send_file can take minutes. Handled one at a time, the client's ping
  // waited behind it and the client took the server for hung.
  test('a slow tool call does not hold up a ping', () async {
    final slow = Completer<Map<String, Object?>>();
    final slowClient = _GatedAgentClient(slow.future);
    final input = StreamController<List<int>>();
    final output = StringBuffer();
    final served = McpServer(slowClient).serve(input.stream, output);

    void send(Map<String, Object?> message) =>
        input.add(utf8.encode('${jsonEncode(message)}\n'));
    send({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'send_text',
        'arguments': {'text': 'hi'},
      },
    });
    send({'jsonrpc': '2.0', 'id': 2, 'method': 'ping'});
    await pumpEventQueue();

    final early = const LineSplitter().convert(output.toString());
    expect(early.map((l) => (jsonDecode(l) as Map)['id']), [2]);

    // The slow one still gets its answer, before serve() returns.
    slow.complete({'ok': true, 'message': 'Sent.'});
    await input.close();
    await served;
    final all = const LineSplitter().convert(output.toString());
    expect(all.map((l) => (jsonDecode(l) as Map)['id']), [2, 1]);
  });

  // The schema used to list a hand-picked few, so an assistant validating
  // against it could not use names the app accepts, such as "mac".
  test('the send tools offer every name the app accepts', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/list',
    });
    final sendText =
        ((reply!['result']! as Map)['tools']! as List).first as Map;
    final to = (sendText['inputSchema']! as Map)['properties']! as Map;
    final names = ((to['to']! as Map)['items']! as Map)['enum'];
    expect(names, containsAll(['mac', 'pc', 'phone', 'ios', 'linux']));
  });

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

  // One-way by definition: no reply, even for a method that has one.
  test('a notification gets no reply, whatever its method', () async {
    for (final method in ['ping', 'tools/list', 'notifications/initialized']) {
      expect(await call({'jsonrpc': '2.0', 'method': method}), isNull);
    }
    expect(client.requests, isEmpty);
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

  test('a malformed "to" is refused, never widened to the defaults', () async {
    for (final to in <Object?>[
      'phone',
      [1],
      {'a': 'b'},
    ]) {
      final reply = await call({
        'jsonrpc': '2.0',
        'id': 8,
        'method': 'tools/call',
        'params': {
          'name': 'send_text',
          'arguments': {'text': 'secret', 'to': to},
        },
      });
      expect((reply!['result']! as Map)['isError'], isTrue, reason: '$to');
    }
    expect(client.requests, isEmpty);
  });

  test('send_file wants an absolute path', () async {
    final reply = await call({
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'tools/call',
      'params': {
        'name': 'send_file',
        'arguments': {'path': 'notes.txt'},
      },
    });
    expect((reply!['result']! as Map)['isError'], isTrue);
    expect(client.requests, isEmpty);
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

/// Holds every request until [_answer] completes.
class _GatedAgentClient extends AgentClient {
  _GatedAgentClient(this._answer) : super(secretPath: '/unused');

  final Future<Map<String, Object?>> _answer;

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> command) => _answer;
}
