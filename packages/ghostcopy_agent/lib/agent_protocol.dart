// What the `ghostcopy` command line (and its MCP server) and the running
// desktop app agree on. Pure Dart - no Flutter - because bin/ghostcopy.dart
// is compiled on its own and must not drag the engine in.
//
// The command line never signs in or touches the session itself. It asks the
// GhostCopy already running in the tray to do the work, over the same
// authenticated loopback channel a second launch uses to hand over a
// ghostcopy:// callback (see SingleInstance). That keeps one session per user:
// a second process restoring and refreshing the same Supabase session would
// rotate the refresh token out from under the running app, and reuse
// detection then revokes both.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The one port every user's GhostCopy listened on before the command line,
/// and so where an out-of-date copy is still found. Per-user ports start
/// just above it, so anything here really is one of those.
const int agentBasePort = 47821;

/// The loopback port this user's app listens on.
///
/// Per user, not one for the machine: loopback is shared by every login
/// session, so with a fixed port a second user's GhostCopy found the first
/// user's holding it, "forwarded" its launch there - accepted by the socket,
/// refused by the secret - and quit, and its command line talked to the wrong
/// app. Derived from the home folder, which the app and the command line see
/// alike, into a 1000-port range above [agentBasePort]. Two users landing on
/// the same port is the old behaviour, not a new failure.
///
/// Case is folded only on Windows, whose paths ignore it; on Linux
/// `/home/Sam` and `/home/sam` are two users.
int agentPortFor({Map<String, String>? environment, bool? windows}) {
  final env = environment ?? Platform.environment;
  final foldCase = windows ?? Platform.isWindows;
  final home = env['USERPROFILE'] ?? env['HOME'];
  if (home == null || home.isEmpty) return agentBasePort + 1;
  // FNV-1a: stable across runs and Dart versions, unlike String.hashCode.
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(foldCase ? home.toLowerCase() : home)) {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return agentBasePort + 1 + hash % 1000;
}

/// Sent first, so the app can tell GhostCopy from an unrelated process that
/// happens to hold the port. Also in every proof, so a proof made for one
/// version of the handshake means nothing to another. Version 1 sent the
/// secret itself; see "The handshake" below.
const String agentHandshakeMagic = 'ghostcopy/2';

/// The device types a clip can be addressed to, in the order the app lists
/// them. ClipboardRepository.validDeviceTypes is this list.
const List<String> deviceTypes = [
  'windows',
  'macos',
  'android',
  'ios',
  'linux',
];

/// Friendlier names an agent or a person is likely to use.
const Map<String, List<String>> deviceAliases = {
  'phone': ['android', 'ios'],
  'mobile': ['android', 'ios'],
  'iphone': ['ios'],
  'desktop': ['windows', 'macos', 'linux'],
  'computer': ['windows', 'macos', 'linux'],
  'mac': ['macos'],
  'pc': ['windows'],
};

/// Every name a destination accepts: the friendly ones, then the types.
final List<String> deviceTargetNames = List.unmodifiable([
  ...deviceAliases.keys,
  ...deviceTypes,
]);

/// The most text one clip can carry, in UTF-16 code units - what
/// ClipboardRepository accepts. Checked before sending, so text the app
/// would refuse never crosses the loopback channel.
const int agentMaxTextLength = 102400;

/// The shared secret's file name, in the app's support directory.
const String agentSecretFileName = 'single_instance.secret';

/// The commands the app answers. Also the MCP tool names.
abstract final class AgentCommand {
  static const String sendText = 'send_text';
  static const String sendFile = 'send_file';
  static const String listDevices = 'list_devices';
}

/// What an `error` code means for whoever asked.
enum AgentErrorKind {
  /// The request was malformed before it was sent.
  usage,

  /// GhostCopy could not be asked, or not yet: worth trying again later.
  unreachable,

  /// GhostCopy answered no. Asking again the same way will not change that.
  refused,

  /// GhostCopy tried, and the send failed - offline, rate limited.
  failed,

  /// The request went and no answer came back, so it may have happened.
  unconfirmed,
}

/// The `error` codes in an answer and in an [AgentException], stable for
/// scripts. One list, so the app and the command line cannot drift apart.
abstract final class AgentError {
  static const String usage = 'usage';
  static const String disabled = 'disabled';
  static const String signedOut = 'signed_out';
  static const String badRequest = 'bad_request';
  static const String sendFailed = 'send_failed';
  static const String notReady = 'not_ready';
  static const String unauthorized = 'unauthorized';
  static const String notInstalled = 'not_installed';
  static const String notRunning = 'not_running';
  static const String outdated = 'outdated';
  static const String untrusted = 'untrusted';
  static const String timeout = 'timeout';
  static const String connectionLost = 'connection_lost';

  /// Anything unknown - an app newer than this command line - is a refusal,
  /// which at least does not invite a retry.
  static AgentErrorKind kindOf(Object? code) => switch (code) {
    AgentError.usage => AgentErrorKind.usage,
    AgentError.sendFailed => AgentErrorKind.failed,
    AgentError.timeout ||
    AgentError.connectionLost => AgentErrorKind.unconfirmed,
    AgentError.notReady ||
    AgentError.unauthorized ||
    AgentError.notInstalled ||
    AgentError.notRunning ||
    AgentError.outdated ||
    AgentError.untrusted => AgentErrorKind.unreachable,
    _ => AgentErrorKind.refused,
  };
}

/// A failed answer: `ok`, the [AgentError] code, and a message for a person.
Map<String, Object?> agentErrorReply(String code, String message) => {
  'ok': false,
  'error': code,
  'message': message,
};

/// [to] as it arrives from outside - an assistant, another process - checked
/// for shape before [resolveDeviceTargets]. Null is the default devices;
/// anything but a list of names is a [FormatException], never the defaults,
/// which can be every device.
List<String> parseDeviceTargets(Object? to) {
  if (to == null) return const [];
  if (to is! List || to.any((t) => t is! String)) {
    throw const FormatException(
      'to must be a list of device names, such as ["phone"].',
    );
  }
  return resolveDeviceTargets(to.cast<String>());
}

/// Turn what the caller asked for into device types, or throw a
/// [FormatException] naming what was not understood. Empty in, empty out -
/// which means "the user's default", not "nowhere".
///
/// A blank name is an error, not skipped: `--to ""` from an empty shell
/// variable, or `["  "]`, would otherwise come out empty and so mean the
/// defaults, which can be every device - wider than anything asked for.
List<String> resolveDeviceTargets(Iterable<String> requested) {
  final resolved = <String>{};
  for (final raw in requested) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) {
      throw const FormatException(
        'A device name is empty. Name one, such as phone, or leave out the '
        'destination to use the default devices.',
      );
    }
    if (deviceTypes.contains(name)) {
      resolved.add(name);
    } else if (deviceAliases.containsKey(name)) {
      resolved.addAll(deviceAliases[name]!);
    } else {
      throw FormatException(
        'Unknown device "$raw". Use one of: ${deviceTargetNames.join(', ')}.',
      );
    }
  }
  return resolved.toList();
}

/// The Microsoft Store package's family name: the Partner Center
/// reservation's identity and publisher (msix_config in the app's
/// pubspec.yaml). Spelled out because the command line runs outside the
/// package and cannot ask Windows for it.
const String storePackageFamilyName = 'g1mli.GhostCopy_41asz506sbn22';

/// Where the shared secret lives: the app's support directory.
///
/// On Windows that depends on how GhostCopy was installed. A Store install
/// keeps its data in its package's LocalState, which Windows deletes with it
/// (the app's PackagedAppData); an unpackaged build uses path_provider's
/// %APPDATA%\<CompanyName>\<ProductName>, from Runner.rc. The Store one is
/// tried first, since that is how GhostCopy is installed. [exists] is for
/// tests.
String defaultSecretPath({
  Map<String, String>? environment,
  bool Function(String path)? exists,
}) {
  final env = environment ?? Platform.environment;
  final override = env['GHOSTCOPY_SECRET_FILE'];
  if (override != null && override.isNotEmpty) return override;
  const file = agentSecretFileName;
  if (Platform.isWindows) {
    final local = env['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      final packaged =
          '$local\\Packages\\$storePackageFamilyName\\LocalState\\$file';
      if ((exists ?? (path) => File(path).existsSync())(packaged)) {
        return packaged;
      }
    }
    return '${env['APPDATA']}\\com.ghostcopy\\ghostcopy\\$file';
  }
  final home = env['HOME'] ?? '';
  if (Platform.isMacOS) {
    return '$home/Library/Application Support/com.ghostcopy.ghostcopy/$file';
  }
  final data = env['XDG_DATA_HOME'] ?? '$home/.local/share';
  return '$data/com.ghostcopy.ghostcopy/$file';
}

/// Why a request could not be answered. [code] is stable for scripts;
/// [message] is for a person.
class AgentException implements Exception {
  const AgentException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Asks the running app to do something and returns its answer.
class AgentClient {
  AgentClient({
    int? port,
    String? secretPath,
    this.timeout = const Duration(minutes: 6),
    this.legacyPort = agentBasePort,
  }) : port = port ?? agentPortFor(),
       secretPath = secretPath ?? defaultSecretPath();

  final int port;
  final String secretPath;

  /// Where GhostCopy listened before ports were per user. Settable for tests.
  final int legacyPort;

  /// Longer than the app's own upload deadline (five minutes, in
  /// TimeoutHttpClient). Giving up first would report a failure while the
  /// app goes on to finish the upload - and a retry would send it twice.
  final Duration timeout;

  Future<Map<String, Object?>> request(Map<String, Object?> command) async {
    final secret = await _readSecret();
    try {
      final reply = await agentSend(
        port: port,
        secret: secret,
        body: {'command': command},
        replyTimeout: timeout,
      );
      return reply!;
    } on AgentException catch (e) {
      if (e.code == AgentError.notRunning) throw await _notRunning();
      rethrow;
    }
  }

  /// Nothing on this user's port. GhostCopy before the command line listened
  /// on [legacyPort] for everyone, so something there is most likely an
  /// out-of-date copy. Only connected to, never sent anything: it may be
  /// another user's, and the secret is not theirs to see.
  Future<AgentException> _notRunning() async {
    if (port != legacyPort) {
      try {
        final legacy = await Socket.connect(
          InternetAddress.loopbackIPv4,
          legacyPort,
          timeout: const Duration(milliseconds: 500),
        );
        legacy.destroy();
        return const AgentException(
          AgentError.outdated,
          'GhostCopy is running but is too old to use from the command line. '
          'Update it to the latest version, then try again.',
        );
      } on SocketException {
        // Nothing there either.
      }
    }
    return const AgentException(
      AgentError.notRunning,
      'GhostCopy is not running. Open it, then try again.',
    );
  }

  Future<String> _readSecret() async {
    final file = File(secretPath);
    if (!file.existsSync()) {
      throw const AgentException(
        AgentError.notInstalled,
        'GhostCopy has not run on this computer yet. Install and open it '
        'first.',
      );
    }
    try {
      return (await file.readAsString()).trim();
    } on FileSystemException catch (e) {
      throw AgentException(
        AgentError.notInstalled,
        "GhostCopy's settings could not be read (${e.message}). Open GhostCopy "
        'and try again.',
      );
    } on FormatException {
      // Not UTF-8: damaged, or not the file GhostCopy wrote. Reported like
      // any other unreadable file, not left to escape as an uncaught error.
      throw AgentException(
        AgentError.notInstalled,
        "GhostCopy's settings file is damaged ($secretPath). Delete it, then "
        'quit and reopen GhostCopy.',
      );
    }
  }
}

// ========== THE HANDSHAKE ==========
//
// Both ends hold the same secret, and neither ever sends it. Each proves it
// knows it with an HMAC over two fresh nonces, one from each side:
//
//   client -> {"magic", "nonce": c}
//   app    -> {"nonce": s, "proof": HMAC(secret, "app" | c | s)}
//   client -> {"proof": HMAC(secret, "client" | c | s), "command" or "args"}
//   app    -> the answer, to a command
//
// The client checks the app's proof before it sends anything that matters,
// so a process squatting the port - another user's, while GhostCopy is
// closed - learns neither the secret nor the request. Version 1 sent the
// secret first and unchecked, so whoever held the port got both, and with
// the secret could later hand the real app a ghostcopy:// sign-in of their
// choosing. The role is in each proof so one side's can never be replayed
// as the other's, and with a fresh nonce from each side no proof is any use
// a second time.
//
// One JSON object per line, in each direction.

/// A fresh random value for one handshake.
String agentNonce() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
}

/// What [role] (`app` or `client`) sends to prove it holds [secret], for
/// this pair of nonces.
String agentProof(
  String secret,
  String role,
  String clientNonce,
  String serverNonce,
) => base64Url.encode(
  Hmac(sha256, utf8.encode(secret))
      .convert(
        utf8.encode('$agentHandshakeMagic|$role|$clientNonce|$serverNonce'),
      )
      .bytes,
);

/// Whether [offered] is [expected], compared without leaking where the first
/// difference is.
bool agentProofMatches(Object? offered, String expected) {
  if (offered is! String) return false;
  final a = utf8.encode(offered);
  final b = utf8.encode(expected);
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// [message] as one handshake line.
List<int> agentFrame(Map<String, Object?> message) =>
    utf8.encode('${jsonEncode(message)}\n');

/// The messages arriving on one connection, a line at a time.
///
/// Bounded: [next] gives up once [maxBytes] arrive without a line ending,
/// so a peer cannot make the reader hold more than that.
class AgentFrames {
  AgentFrames(Stream<List<int>> input, {this.maxBytes = 1024 * 1024})
    : _input = StreamIterator(input);

  final StreamIterator<List<int>> _input;
  final int maxBytes;
  final List<int> _pending = [];

  /// How much of [_pending] is known to hold no line ending.
  int _scanned = 0;

  /// The next message, or null: the connection ended, the line was not a
  /// JSON object, or it ran past [maxBytes].
  Future<Map<String, Object?>?> next() async {
    while (true) {
      final end = _pending.indexOf(0x0A, _scanned);
      if (end != -1) {
        final line = _pending.sublist(0, end);
        _pending.removeRange(0, end + 1);
        _scanned = 0;
        try {
          final decoded = jsonDecode(utf8.decode(line));
          return decoded is Map<String, Object?> ? decoded : null;
        } on FormatException {
          return null;
        }
      }
      _scanned = _pending.length;
      if (_pending.length > maxBytes) return null;
      if (!await _input.moveNext()) return null;
      _pending.addAll(_input.current);
    }
  }
}

/// Run the client side of the handshake with the GhostCopy on [port], then
/// send [body] - a `command`, or a second launch's `args`. Returns the
/// answer, or null when not [awaitReply].
///
/// Throws an [AgentException]: [AgentError.notRunning] when nothing is
/// listening, [AgentError.untrusted] when what is listening cannot prove it
/// is GhostCopy - in which case nothing in [body] was sent - and, once
/// [body] has gone, [AgentError.timeout] or [AgentError.connectionLost].
Future<Map<String, Object?>?> agentSend({
  required int port,
  required String secret,
  required Map<String, Object?> body,
  bool awaitReply = true,
  Duration connectTimeout = const Duration(seconds: 2),
  Duration handshakeTimeout = const Duration(seconds: 5),
  Duration replyTimeout = const Duration(minutes: 6),
}) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: connectTimeout,
    );
  } on SocketException {
    throw const AgentException(
      AgentError.notRunning,
      'GhostCopy is not running. Open it, then try again.',
    );
  }
  final frames = AgentFrames(socket);
  var sent = false;
  try {
    final clientNonce = agentNonce();
    socket.add(
      agentFrame({'magic': agentHandshakeMagic, 'nonce': clientNonce}),
    );
    final hello = await frames.next().timeout(handshakeTimeout);
    final serverNonce = hello?['nonce'];
    if (serverNonce is! String ||
        !agentProofMatches(
          hello!['proof'],
          agentProof(secret, 'app', clientNonce, serverNonce),
        )) {
      throw const AgentException(AgentError.untrusted, _untrustedMessage);
    }
    socket.add(
      agentFrame({
        'proof': agentProof(secret, 'client', clientNonce, serverNonce),
        ...body,
      }),
    );
    await socket.flush();
    sent = true;
    if (!awaitReply) return null;
    final reply = await frames.next().timeout(replyTimeout);
    if (reply == null) throw const SocketException('closed without an answer');
    return reply;
  } on AgentException {
    rethrow;
  } on Object catch (e) {
    if (!sent) {
      throw const AgentException(AgentError.untrusted, _untrustedMessage);
    }
    // The request had gone, so it may have been acted on: not "not
    // running", which invites a retry that sends it twice.
    if (e is TimeoutException) {
      throw const AgentException(
        AgentError.timeout,
        'GhostCopy took too long to answer. It may still have sent this - '
        'check your history before trying again.',
      );
    }
    throw const AgentException(
      AgentError.connectionLost,
      'GhostCopy closed the connection before answering. It may still have '
      'sent this - check your history before trying again.',
    );
  } finally {
    socket.destroy();
  }
}

const String _untrustedMessage =
    "Something is answering on GhostCopy's port but could not prove it is "
    'GhostCopy, so nothing was sent to it. If GhostCopy is open, quit and '
    'reopen it, then try again.';
