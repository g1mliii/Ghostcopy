// `ghostcopy mcp`: a Model Context Protocol server over standard input and
// output, for assistants without a shell - Claude Desktop, ChatGPT and the
// like. Each tool is one request to the running app through [AgentClient],
// the same as the command line, so there is one implementation behind both.
//
// Transport is newline-delimited JSON-RPC 2.0. Standard output carries
// protocol messages only; anything for a person goes to [log] (stderr).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_protocol.dart';

/// Protocol revisions this server speaks, newest first.
const List<String> mcpProtocolVersions = [
  '2025-06-18',
  '2025-03-26',
  '2024-11-05',
];

/// `to`, as both send tools describe it: every name the app accepts.
final Map<String, Object?> _toProperty = {
  'type': 'array',
  'items': {'type': 'string', 'enum': deviceTargetNames},
  'description':
      'Where to send it. Any of: ${deviceTargetNames.join(', ')}. '
      "Leave out to use the user's default devices.",
};

/// The tools, as tools/list describes them.
final List<Map<String, Object?>> mcpTools = [
  {
    'name': AgentCommand.sendText,
    'title': 'Send text with GhostCopy',
    'description':
        "Send text or a link to the user's other devices through GhostCopy. "
        'It arrives in their GhostCopy history and as a notification on '
        'their phone. Reports that it was sent, not that it was seen.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'The text or link to send.'},
        'to': _toProperty,
      },
      'required': ['text'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false},
  },
  {
    'name': AgentCommand.sendFile,
    'title': 'Send a file with GhostCopy',
    'description':
        "Send a file on this computer to the user's other devices through "
        'GhostCopy, up to 10 MB. The path must be absolute.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Absolute path to the file.'},
        'to': _toProperty,
      },
      'required': ['path'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false},
  },
  {
    'name': AgentCommand.listDevices,
    'title': 'List GhostCopy devices',
    'description':
        "List the devices on the user's GhostCopy account, with their type, "
        'so a send can be aimed at the right one.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    'annotations': {'readOnlyHint': true},
  },
];

class McpServer {
  McpServer(this._client, {this.version = '1.0.0'});

  final AgentClient _client;
  final String version;

  /// Answer messages from [input] on [output] until [input] ends, and every
  /// answer is written.
  ///
  /// Each message is handled as it arrives, not after the one before it has
  /// been answered: a send_file can take minutes, and a client whose `ping`
  /// goes unanswered meanwhile takes the server for hung. Replies carry their
  /// request's id, so their order does not matter, and each is one writeln -
  /// a whole line - so they cannot interleave.
  Future<void> serve(
    Stream<List<int>> input,
    StringSink output, {
    StringSink? log,
  }) async {
    final lines = input.transform(utf8.decoder).transform(const LineSplitter());
    // Only the unanswered ones: a long session would otherwise keep every
    // message it ever handled.
    final pending = <Future<void>>{};
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      late final Future<void> answered;
      answered = handleLine(line, log: log)
          .then((reply) {
            if (reply != null) output.writeln(jsonEncode(reply));
          })
          .whenComplete(() => pending.remove(answered));
      pending.add(answered);
    }
    await Future.wait(pending.toList());
  }

  /// One message in, at most one message out. Notifications get no reply.
  Future<Map<String, Object?>?> handleLine(
    String line, {
    StringSink? log,
  }) async {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return _error(null, -32700, 'Parse error');
    }
    if (message is! Map<String, Object?>) {
      return _error(null, -32600, 'Invalid request');
    }
    final id = message['id'];
    final method = message['method'];
    final params = message['params'];
    final isNotification = !message.containsKey('id');
    if (method is! String) {
      return isNotification ? null : _error(id, -32600, 'Invalid request');
    }

    switch (method) {
      case 'initialize':
        final requested = params is Map ? params['protocolVersion'] : null;
        return _result(id, {
          'protocolVersion': mcpProtocolVersions.contains(requested)
              ? requested
              : mcpProtocolVersions.first,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'ghostcopy', 'version': version},
          'instructions':
              "Sends text, links and files to the user's other devices "
              '(phone, computer) through the GhostCopy app running on this '
              'computer. Use list_devices to see what they have.',
        });
      case 'ping':
        return _result(id, <String, Object?>{});
      case 'tools/list':
        return _result(id, {'tools': mcpTools});
      case 'tools/call':
        if (params is! Map) return _error(id, -32602, 'Invalid params');
        final name = params['name'];
        final arguments = params['arguments'];
        return _result(
          id,
          await _callTool(
            name,
            arguments is Map<String, Object?> ? arguments : const {},
          ),
        );
      default:
        if (isNotification) return null;
        log?.writeln('[ghostcopy mcp] unsupported method $method');
        return _error(id, -32601, 'Method not found: $method');
    }
  }

  Future<Map<String, Object?>> _callTool(
    Object? name,
    Map<String, Object?> arguments,
  ) async {
    final Map<String, Object?> request;
    try {
      final targets = parseDeviceTargets(arguments['to']);
      switch (name) {
        case AgentCommand.sendText:
          final text = arguments['text'];
          if (text is! String || text.trim().isEmpty) {
            return _toolError('text is required and cannot be empty.');
          }
          if (text.length > agentMaxTextLength) {
            return _toolError(
              'text is too long: GhostCopy takes up to $agentMaxTextLength '
              'characters. Save it to a file and use send_file instead.',
            );
          }
          request = {
            'name': AgentCommand.sendText,
            'text': text,
            'to': targets,
          };
        case AgentCommand.sendFile:
          final path = arguments['path'];
          if (path is! String || path.trim().isEmpty) {
            return _toolError('path is required.');
          }
          // The app is another process with its own working directory, so a
          // relative path would resolve somewhere else - possibly to a
          // different file of the same name.
          if (!File(path).isAbsolute) {
            return _toolError('path must be absolute: $path');
          }
          request = {
            'name': AgentCommand.sendFile,
            'path': path,
            'to': targets,
          };
        case AgentCommand.listDevices:
          request = {'name': AgentCommand.listDevices};
        default:
          return _toolError('Unknown tool: $name');
      }
    } on FormatException catch (e) {
      return _toolError(e.message);
    }

    try {
      final reply = await _client.request(request);
      if (reply['ok'] != true) {
        return _toolError(reply['message'] as String? ?? 'GhostCopy refused.');
      }
      if (name == AgentCommand.listDevices) {
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(reply['devices'] ?? const [])},
          ],
        };
      }
      return {
        'content': [
          {'type': 'text', 'text': reply['message'] as String? ?? 'Sent.'},
        ],
      };
    } on AgentException catch (e) {
      return _toolError(e.message);
    }
  }

  /// A failed call is still a successful response: the assistant should see
  /// why and can tell the user, which a protocol error would hide.
  Map<String, Object?> _toolError(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };

  Map<String, Object?> _result(Object? id, Map<String, Object?> result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}
