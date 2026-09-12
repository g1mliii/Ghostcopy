import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Keeps exactly one desktop instance of GhostCopy alive, and forwards
/// command-line arguments from any later launch into it.
///
/// Windows registers `ghostcopy://` as `"<exe>" "%1"`, so completing Google
/// OAuth starts a SECOND copy of the app - a second window, a second tray icon
/// and a second global hotkey registration - and the callback URL is delivered
/// to that new process, which the running one never sees. The browser is then
/// left sitting on the callback page because nothing ever signed in.
///
/// Implemented with a loopback socket rather than a lock file: a lock file left
/// behind by a crash would block every future launch, whereas a socket is
/// released by the OS when the process dies. It binds to 127.0.0.1 only, so it
/// is not reachable off the machine.
class SingleInstance {
  SingleInstance._();

  static final SingleInstance instance = SingleInstance._();

  /// Arbitrary high port. Only ever contacted by another copy of this app.
  static const int _port = 47821;

  ServerSocket? _server;

  final StreamController<String> _incoming = StreamController<String>.broadcast();

  /// Arguments handed over by later launches (e.g. a `ghostcopy://` callback).
  Stream<String> get incomingArguments => _incoming.stream;

  /// Returns true if this process is the primary instance and should continue
  /// starting up. Returns false if another instance already owns the port, in
  /// which case [args] have been forwarded to it and this process should exit.
  Future<bool> acquire(List<String> args) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen(_handleConnection);
      debugPrint('[SingleInstance] ✅ Primary instance (port $_port)');
      return true;
    } on SocketException {
      // Port taken: another instance is already running.
      debugPrint('[SingleInstance] Another instance owns port $_port');
      await _forward(args);
      return false;
    }
  }

  void _handleConnection(Socket socket) {
    socket
        .cast<List<int>>()
        .transform(const SystemEncoding().decoder)
        .join()
        .then((payload) {
      final trimmed = payload.trim();
      debugPrint('[SingleInstance] ← Received from second launch: $trimmed');
      if (trimmed.isNotEmpty) _incoming.add(trimmed);
    }).whenComplete(() => socket.destroy());
  }

  Future<void> _forward(List<String> args) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(seconds: 2),
      );
      socket.write(args.join(' '));
      await socket.flush();
      await socket.close();
      debugPrint('[SingleInstance] → Forwarded args to primary instance');
    } on Exception catch (e) {
      // The primary may be shutting down. Nothing useful to do: this process is
      // about to exit either way.
      debugPrint('[SingleInstance] ⚠️ Could not forward args: $e');
    }
  }

  Future<void> dispose() async {
    await _server?.close();
    await _incoming.close();
  }
}
