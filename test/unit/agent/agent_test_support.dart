import 'package:ghostcopy_agent/agent_protocol.dart';

/// Answers requests without a running app, and records what was asked.
class FakeAgentClient extends AgentClient {
  FakeAgentClient({this.reply, this.error}) : super(secretPath: '/unused');

  Map<String, Object?> Function(Map<String, Object?> command)? reply;
  AgentException? error;
  final List<Map<String, Object?>> requests = [];

  @override
  Future<Map<String, Object?>> request(Map<String, Object?> command) async {
    requests.add(command);
    final failure = error;
    if (failure != null) throw failure;
    return reply?.call(command) ?? {'ok': true, 'message': 'Sent.'};
  }
}
