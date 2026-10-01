import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';

void main() {
  group('resolveDeviceTargets', () {
    test('passes device types through', () {
      expect(resolveDeviceTargets(['ios', 'windows']), ['ios', 'windows']);
    });

    test('expands the names people use', () {
      expect(resolveDeviceTargets(['phone']), ['android', 'ios']);
      expect(resolveDeviceTargets(['Desktop']), ['windows', 'macos']);
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
