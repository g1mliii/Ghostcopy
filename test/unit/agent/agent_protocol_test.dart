import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';
import 'package:ghostcopy_agent/cli.dart';

void main() {
  group('resolveDeviceTargets', () {
    test('passes device types through', () {
      expect(resolveDeviceTargets(['ios', 'windows']), ['ios', 'windows']);
    });

    test('expands the names people use', () {
      expect(resolveDeviceTargets(['phone']), ['android', 'ios']);
      expect(resolveDeviceTargets(['Desktop']), ['windows', 'macos', 'linux']);
      expect(resolveDeviceTargets(['linux']), ['linux']);
      expect(resolveDeviceTargets(['phone', 'ios']), ['android', 'ios']);
    });

    test('nothing asked for means the default, not nowhere', () {
      expect(resolveDeviceTargets(const []), isEmpty);
    });

    // A blank name used to be skipped, so `--to ""` came out empty - the
    // defaults, which can be every device.
    test('a blank name is an error, not the defaults', () {
      for (final blank in [
        [''],
        ['  '],
        ['phone', ''],
      ]) {
        expect(
          () => resolveDeviceTargets(blank),
          throwsFormatException,
          reason: '$blank',
        );
      }
    });

    test('names what it did not understand', () {
      expect(
        () => resolveDeviceTargets(['toaster']),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('toaster'),
          ),
        ),
      );
    });
  });

  group('parseDeviceTargets', () {
    test('null is the defaults, a list is resolved', () {
      expect(parseDeviceTargets(null), isEmpty);
      expect(parseDeviceTargets(['mac']), ['macos']);
    });

    // From outside, a malformed `to` must never become the defaults.
    test('anything but a list of names is an error', () {
      for (final bad in [
        'phone',
        [1],
        ['phone', null],
        {'to': 'phone'},
      ]) {
        expect(
          () => parseDeviceTargets(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  test('every error code has the kind the command line exits with', () {
    expect(AgentError.kindOf(AgentError.timeout), AgentErrorKind.unconfirmed);
    expect(AgentError.kindOf(AgentError.sendFailed), AgentErrorKind.failed);
    expect(AgentError.kindOf(AgentError.notReady), AgentErrorKind.unreachable);
    expect(AgentError.kindOf(AgentError.outdated), AgentErrorKind.unreachable);
    expect(AgentError.kindOf(AgentError.disabled), AgentErrorKind.refused);
    // A code from an app newer than this command line.
    expect(AgentError.kindOf('quota_exceeded'), AgentErrorKind.refused);
  });

  group('agentPortFor', () {
    test('is the same for the same user, every time', () {
      final env = {'HOME': '/Users/sam'};
      expect(agentPortFor(environment: env), agentPortFor(environment: env));
    });

    test('differs between users, inside the range', () {
      final a = agentPortFor(environment: {'HOME': '/Users/sam'});
      final b = agentPortFor(environment: {'HOME': '/Users/alex'});
      expect(a, isNot(b));
      for (final port in [a, b]) {
        expect(port, inInclusiveRange(agentBasePort + 1, agentBasePort + 1000));
      }
    });

    test('Windows home folders compare without case', () {
      expect(
        agentPortFor(
          environment: {'USERPROFILE': r'C:\Users\Sam'},
          windows: true,
        ),
        agentPortFor(
          environment: {'USERPROFILE': r'c:\users\sam'},
          windows: true,
        ),
      );
    });

    test('elsewhere, case-distinct homes are different users', () {
      expect(
        agentPortFor(environment: {'HOME': '/home/Sam'}, windows: false),
        isNot(agentPortFor(environment: {'HOME': '/home/sam'}, windows: false)),
      );
    });

    test('no home folder falls back to the base port', () {
      expect(agentPortFor(environment: const {}), agentBasePort + 1);
    });
  });

  test('an app that drops the connection is an AgentException', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());
    final secret = File('${Directory.systemTemp.createTempSync('a').path}/s')
      ..writeAsStringSync('x' * 40);

    await expectLater(
      AgentClient(
        port: server.port,
        secretPath: secret.path,
      ).request({'name': 'list_devices'}),
      throwsA(isA<AgentException>()),
    );
  });

  // The app took the command, then quit before answering: it may have sent
  // the clip, so this is "check before retrying", never "not running".
  for (final jsonOutput in [false, true]) {
    test('a send with no answer is unconfirmed (json: $jsonOutput)', () async {
      final directory = await Directory.systemTemp.createTemp('agent-reply');
      addTearDown(() => directory.delete(recursive: true));
      const secret = 'x-secret-for-the-handshake-0123456789abcdef';
      final secretFile = File('${directory.path}/secret');
      await secretFile.writeAsString(secret);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = Completer<Map<String, Object?>>();
      final subscription = server.listen((socket) {
        unawaited(() async {
          final frames = AgentFrames(socket);
          try {
            // A real app's side of the handshake...
            final hello = await frames.next();
            final clientNonce = hello!['nonce']! as String;
            const serverNonce = 'server-nonce';
            socket.add(
              agentFrame({
                'nonce': serverNonce,
                'proof': agentProof(secret, 'app', clientNonce, serverNonce),
              }),
            );
            final request = await frames.next();
            received.complete(request!['command']! as Map<String, Object?>);
            // ...that has the command, then exits before replying.
            await socket.close();
          } finally {
            socket.destroy();
          }
        }());
      });
      addTearDown(subscription.cancel);
      final out = StringBuffer();
      final err = StringBuffer();

      final exit = await runCli(
        ['send', 'hello', if (jsonOutput) '--json'],
        client: AgentClient(port: server.port, secretPath: secretFile.path),
        out: out,
        err: err,
      );

      expect(await received.future, {
        'name': 'send_text',
        'text': 'hello',
        'to': <String>[],
      });
      expect(exit, CliExit.unconfirmed);
      final String message;
      if (jsonOutput) {
        final reply = jsonDecode(out.toString()) as Map<String, Object?>;
        expect(reply['ok'], isFalse);
        expect(reply['error'], AgentError.connectionLost);
        message = reply['message']! as String;
        expect(err.toString(), isEmpty);
      } else {
        message = err.toString();
        expect(out.toString(), isEmpty);
      }
      expect(message, contains('may still have sent this'));
      expect(message, contains('check your history before trying again'));
    });
  }

  // The point of the handshake: whatever holds the port without being
  // GhostCopy - another user's process while the app is closed - learns
  // neither the secret nor what was being sent.
  group('a port held by something that is not GhostCopy', () {
    late File secretFile;
    const secret = 'the-real-secret-that-must-not-leak-0123456789';

    setUp(() {
      secretFile = File('${Directory.systemTemp.createTempSync('h').path}/s')
        ..writeAsStringSync(secret);
    });

    Future<(ServerSocket, List<int>)> squatter({required bool answers}) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final received = <int>[];
      server.listen((socket) {
        socket.listen((bytes) {
          received.addAll(bytes);
          // It does not know the secret, so its "proof" is a guess.
          if (answers) {
            socket.add(agentFrame({'nonce': 'x', 'proof': 'guess'}));
          }
        });
      });
      return (server, received);
    }

    test('is told nothing when its proof is wrong', () async {
      final (server, received) = await squatter(answers: true);

      await expectLater(
        AgentClient(
          port: server.port,
          secretPath: secretFile.path,
        ).request({'name': 'send_text', 'text': 'private clip'}),
        throwsA(
          isA<AgentException>().having((e) => e.code, 'code', 'untrusted'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final seen = utf8.decode(received);
      expect(seen, isNot(contains(secret)));
      expect(seen, isNot(contains('private clip')));
    });

    test('is told nothing when it does not answer', () async {
      final (server, received) = await squatter(answers: false);

      await expectLater(
        agentSend(
          port: server.port,
          secret: secret,
          body: {
            'command': {'name': 'send_text', 'text': 'private clip'},
          },
          handshakeTimeout: const Duration(milliseconds: 300),
        ),
        throwsA(
          isA<AgentException>().having((e) => e.code, 'code', 'untrusted'),
        ),
      );
      final seen = utf8.decode(received);
      expect(seen, isNot(contains(secret)));
      expect(seen, isNot(contains('private clip')));
    });
  });

  test('a proof is bound to its role and its nonces', () {
    final proof = agentProof('s', 'app', 'c', 'n');
    expect(agentProofMatches(proof, agentProof('s', 'app', 'c', 'n')), isTrue);
    expect(
      agentProofMatches(proof, agentProof('s', 'client', 'c', 'n')),
      isFalse,
    );
    expect(
      agentProofMatches(proof, agentProof('s', 'app', 'c2', 'n')),
      isFalse,
    );
    expect(agentProofMatches(proof, agentProof('t', 'app', 'c', 'n')), isFalse);
    expect(agentProofMatches(null, proof), isFalse);
  });

  group("nothing on this user's port", () {
    late File secret;
    late int closedPort;

    setUp(() async {
      secret = File('${Directory.systemTemp.createTempSync('p').path}/s')
        ..writeAsStringSync('x' * 40);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      closedPort = probe.port;
      await probe.close();
    });

    test('is "not running" when the old shared port is free too', () async {
      final legacy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = legacy.port;
      await legacy.close();

      await expectLater(
        AgentClient(
          port: closedPort,
          secretPath: secret.path,
          legacyPort: freePort,
        ).request({'name': 'list_devices'}),
        throwsA(
          isA<AgentException>().having((e) => e.code, 'code', 'not_running'),
        ),
      );
    });

    // GhostCopy before per-user ports listens on the old one; telling its
    // user it is not running sent them looking for the wrong problem.
    test('is "outdated" when something holds the old shared port', () async {
      final legacy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(legacy.close);
      final received = <int>[];
      legacy.listen((socket) => socket.listen(received.addAll));

      await expectLater(
        AgentClient(
          port: closedPort,
          secretPath: secret.path,
          legacyPort: legacy.port,
        ).request({'name': 'list_devices'}),
        throwsA(
          isA<AgentException>().having((e) => e.code, 'code', 'outdated'),
        ),
      );
      // It may be another user's: connected to, never told the secret.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, isEmpty);
    });
  });

  test(
    'an unreadable secret file is an AgentException, not a crash',
    () async {
      final secret = File('${Directory.systemTemp.createTempSync('u').path}/s')
        ..writeAsStringSync('x' * 40);
      await Process.run('chmod', ['000', secret.path]);
      addTearDown(() => Process.run('chmod', ['600', secret.path]));

      await expectLater(
        AgentClient(secretPath: secret.path).request({'name': 'list_devices'}),
        throwsA(isA<AgentException>()),
      );
    },
    skip: Platform.isWindows ? 'chmod is POSIX' : false,
  );

  test('the secret path can be overridden', () {
    expect(
      defaultSecretPath(environment: {'GHOSTCOPY_SECRET_FILE': '/tmp/s'}),
      '/tmp/s',
    );
  });

  test('a missing secret file says GhostCopy has not run here', () async {
    final client = AgentClient(secretPath: '/nonexistent/ghostcopy.secret');
    await expectLater(
      client.request({'name': 'list_devices'}),
      throwsA(
        isA<AgentException>().having((e) => e.code, 'code', 'not_installed'),
      ),
    );
  });
}
