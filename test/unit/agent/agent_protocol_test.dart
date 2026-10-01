import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';

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
      expect(resolveDeviceTargets([' ', '']), isEmpty);
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
        expect(port, inInclusiveRange(agentBasePort, agentBasePort + 999));
      }
    });

    test('Windows home folders compare without case', () {
      expect(
        agentPortFor(environment: {'USERPROFILE': r'C:\Users\Sam'}),
        agentPortFor(environment: {'USERPROFILE': r'c:\users\sam'}),
      );
    });

    test('no home folder falls back to the base port', () {
      expect(agentPortFor(environment: const {}), agentBasePort);
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
