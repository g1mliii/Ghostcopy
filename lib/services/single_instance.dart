import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
///
/// Loopback is NOT a trust boundary, though: every process on the machine,
/// including ones running as other local users, can connect to it. Whatever
/// arrives here is handed to the `ghostcopy://` deep-link handler, so an
/// unauthenticated channel would let any local process complete OAuth into an
/// account of its choosing and then read everything the victim copies. Both
/// ends therefore prove knowledge of a shared secret, stored in a file only
/// this user can read, before any payload is accepted.
class SingleInstance {
  SingleInstance._();

  static final SingleInstance instance = SingleInstance._();

  /// Arbitrary high port. Only ever contacted by another copy of this app.
  static const int _defaultPort = 47821;

  /// The loopback port the primary instance owns.
  ///
  /// Settable only so tests can bind a free one. With a fixed port a test
  /// races any running copy of the app for it and fails on a developer's
  /// machine while passing in CI - which is the wrong way round for a test
  /// that exists to catch a bug users hit.
  @visibleForTesting
  static int port = _defaultPort;

  /// Sent ahead of the payload so the primary can recognise a peer that is
  /// actually GhostCopy, and so a second launch can tell GhostCopy apart from
  /// an unrelated process that happens to hold the port.
  static const String _handshakeMagic = 'ghostcopy/1';

  /// A squatted port must not hang startup; these are generous for loopback.
  static const Duration _connectTimeout = Duration(seconds: 2);
  static const Duration _handshakeTimeout = Duration(seconds: 3);

  ServerSocket? _server;
  String? _secret;

  final StreamController<String> _incoming =
      StreamController<String>.broadcast();

  /// Payloads that arrived before anything subscribed.
  ///
  /// The server starts listening inside [acquire], but main.dart only attaches
  /// its handler after Supabase and the rest of desktop setup finish. A
  /// broadcast stream has no replay, so a `ghostcopy://` callback forwarded in
  /// that window used to be dropped silently - leaving the browser on the
  /// callback page, the exact failure this class exists to prevent.
  final List<String> _pending = <String>[];
  bool _hasListener = false;

  /// Arguments handed over by later launches (e.g. a `ghostcopy://` callback).
  Stream<String> get incomingArguments {
    return _incoming.stream;
  }

  /// Begin delivering forwarded arguments, including any that arrived before
  /// now.
  ///
  /// Prefer this over subscribing to [incomingArguments] directly: it flushes
  /// the startup backlog that a broadcast stream would otherwise discard.
  StreamSubscription<String> listen(void Function(String) onArguments) {
    final subscription = _incoming.stream.listen(onArguments);
    _hasListener = true;
    if (_pending.isNotEmpty) {
      final backlog = List<String>.of(_pending);
      _pending.clear();
      // Deliver after this turn so the caller's subscription is fully wired.
      scheduleMicrotask(() {
        for (final payload in backlog) {
          _incoming.add(payload);
        }
      });
    }
    return subscription;
  }

  /// Test hooks.
  ///
  /// The delivery bug these cover was in the socket handling, so a test has to
  /// speak the real handshake to a real primary instance; that needs the port,
  /// the magic and this process's secret. Exposed narrowly rather than
  /// loosening the fields themselves.
  @visibleForTesting
  static const String handshakeMagic = _handshakeMagic;

  @visibleForTesting
  String? get secret => _secret;

  /// Release the port and forget any backlog, so one test cannot strand the
  /// singleton for the next.
  @visibleForTesting
  Future<void> disposeForTest() async {
    await _server?.close();
    _server = null;
    _hasListener = false;
    _pending.clear();
  }

  void _deliver(String payload) {
    if (_hasListener) {
      _incoming.add(payload);
    } else {
      _pending.add(payload);
    }
  }

  /// Returns true if this process is the primary instance and should continue
  /// starting up. Returns false only when another *GhostCopy* instance owns the
  /// port, in which case [args] have been forwarded to it and this process
  /// should exit.
  ///
  /// If the port is held by something else entirely, this returns true and the
  /// app starts normally without single-instance behaviour - refusing to launch
  /// because an unrelated process happens to use port 47821 would be a silent,
  /// unexplainable failure to start.
  Future<bool> acquire(List<String> args) async {
    _secret = await _loadOrCreateSecret();

    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen(_handleConnection);
      debugPrint('[SingleInstance] ✅ Primary instance (port $port)');
      return true;
    } on SocketException {
      // Port taken - but by whom?
      debugPrint('[SingleInstance] Port $port is in use, probing peer...');
      final forwarded = await _forward(args);
      if (forwarded) return false;

      debugPrint(
        '[SingleInstance] ⚠️ Port $port is held by something that is not '
        'GhostCopy - continuing without single-instance support',
      );
      return true;
    }
  }

  /// Secret shared between instances, stored where only this user can read it.
  ///
  /// Falls back to a process-lifetime random value if the file cannot be used;
  /// that disables arg forwarding (the two sides will disagree) but never
  /// weakens the check, which is the safer direction to fail.
  Future<String> _loadOrCreateSecret() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'single_instance.secret'));

      if (file.existsSync()) {
        final existing = (await file.readAsString()).trim();
        if (existing.length >= 32) return existing;
      }

      final random = Random.secure();
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      final secret = base64Url.encode(bytes);

      await file.parent.create(recursive: true);
      await file.writeAsString(secret, flush: true);

      // Best effort on POSIX; Windows already restricts the per-user
      // application support directory.
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }

      return secret;
    } on Object catch (e) {
      debugPrint('[SingleInstance] ⚠️ Could not persist secret: $e');
      final random = Random.secure();
      return base64Url.encode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
    }
  }

  void _handleConnection(Socket socket) {
    // One JSON line: {"magic": ..., "secret": ..., "args": [...]}.
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(_handshakeTimeout)
        .then((payload) {
          final args = _verifyAndExtract(payload);
          if (args == null) {
            debugPrint(
              '[SingleInstance] ✗ Rejected unauthenticated connection',
            );
            return;
          }
          debugPrint('[SingleInstance] ← Received from second launch: $args');
          // Delivered even when empty, which is the commonest case of all:
          // launching the app while it is already running, with no arguments.
          // That is the user asking for the window, and main.dart handles it
          // explicitly - "a second launch without a URL is the user asking for
          // the app, so show the window rather than silently doing nothing".
          // An `args.isNotEmpty` guard here meant that case was dropped before
          // it ever reached that code, so clicking the app while it sat in the
          // tray did nothing at all.
          _deliver(args);
        })
        .catchError((Object e) {
          debugPrint('[SingleInstance] ⚠️ Connection error: $e');
        })
        .whenComplete(() => socket.destroy());
  }

  /// Returns the forwarded argument string, or null if the peer did not prove
  /// it is another copy of this app running as this user.
  String? _verifyAndExtract(String payload) {
    final trimmed = payload.trim();
    if (trimmed.isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    if (decoded['magic'] != _handshakeMagic) return null;

    final offered = decoded['secret'];
    final expected = _secret;
    if (offered is! String || expected == null) return null;
    if (!_constantTimeEquals(offered, expected)) return null;

    final args = decoded['args'];
    if (args is! List) return null;
    return args.whereType<String>().join(' ').trim();
  }

  /// Compares without leaking where the first difference is.
  ///
  /// The secret is local and long, so this is defence in depth rather than a
  /// response to a practical timing attack - but there is no reason to write
  /// the leaky version.
  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    if (aBytes.length != bBytes.length) return false;
    var diff = 0;
    for (var i = 0; i < aBytes.length; i++) {
      diff |= aBytes[i] ^ bBytes[i];
    }
    return diff == 0;
  }

  /// Hands [args] to the running primary. Returns whether that succeeded, which
  /// is also the answer to "is the process holding the port actually us?".
  Future<bool> _forward(List<String> args) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _connectTimeout,
      );
      final payload = jsonEncode({
        'magic': _handshakeMagic,
        'secret': _secret,
        'args': args,
      });
      socket.add(utf8.encode(payload));
      // close() flushes anything still buffered before the future completes.
      await socket.close();
      debugPrint('[SingleInstance] → Forwarded args to primary instance');
      return true;
    } on Object catch (e) {
      // Either the primary is shutting down, or the port belongs to an
      // unrelated process. Either way we could not hand off.
      debugPrint('[SingleInstance] ⚠️ Could not forward args: $e');
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> dispose() async {
    await _server?.close();
    await _incoming.close();
  }
}
