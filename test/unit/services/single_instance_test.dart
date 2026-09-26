import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/services/single_instance.dart';

/// Drives a real primary instance over its real socket, because the bug this
/// covers lived in the wire handling: the payload arrived, was verified, and
/// was then dropped before reaching the listener. A fake that starts at the
/// stream would have passed the whole time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Speak the handshake a second launch speaks.
  Future<void> forward(int port, String secret, List<String> args) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );
    socket.write(
      jsonEncode({
        'magic': SingleInstance.handshakeMagic,
        'secret': secret,
        'args': args,
      }),
    );
    await socket.flush();
    await socket.close();
  }

  test(
    'a second launch with no arguments still reaches the listener',
    () async {
      // A free port, so this does not race a running copy of the app for the
      // real one.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final realPort = SingleInstance.port;
      SingleInstance.port = probe.port;
      await probe.close();
      addTearDown(() => SingleInstance.port = realPort);

      final instance = SingleInstance.instance;
      final acquired = await instance.acquire(const <String>[]);
      expect(acquired, isTrue, reason: 'nothing else should hold the port');

      final received = Completer<String>();
      final subscription = instance.listen(received.complete);

      // No arguments: the plain "open the app" case, which is what clicking a
      // running app's icon or its Start menu entry sends. The old
      // `args.isNotEmpty` guard swallowed exactly this, so the window never
      // came up and nothing anywhere said why.
      await forward(SingleInstance.port, instance.secret!, const <String>[]);

      final payload = await received.future.timeout(const Duration(seconds: 5));
      expect(payload, isEmpty);

      await subscription.cancel();
      await instance.disposeForTest();
    },
  );
}
