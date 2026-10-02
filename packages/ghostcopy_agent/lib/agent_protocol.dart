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
/// happens to hold the port, and the other way round.
const String agentHandshakeMagic = 'ghostcopy/1';

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
  static const String noAnswer = 'no_answer';
  static const String badAnswer = 'bad_answer';
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
    AgentError.noAnswer ||
    AgentError.badAnswer => AgentErrorKind.unreachable,
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

/// Where the shared secret lives: the app's support directory, as
/// path_provider computes it. Windows is %APPDATA%\<CompanyName>\<ProductName>
/// from Runner.rc, and an MSIX install is not redirected (see CLAUDE.md).
String defaultSecretPath({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final override = env['GHOSTCOPY_SECRET_FILE'];
  if (override != null && override.isNotEmpty) return override;
  const file = agentSecretFileName;
  if (Platform.isWindows) {
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
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
    } on SocketException {
      throw await _notRunning();
    }
    try {
      socket.add(
        utf8.encode(
          jsonEncode({
            'magic': agentHandshakeMagic,
            'secret': secret,
            'command': command,
          }),
        ),
      );
      // Half-close: the app reads until the end of the request, then answers
      // on the same connection.
      await socket.close();
      final reply = await utf8.decoder.bind(socket).join().timeout(timeout);
      // A current app answers every command, a refusal included, so a peer
      // that took the handshake and said nothing predates commands.
      if (reply.trim().isEmpty) {
        throw const AgentException(
          AgentError.noAnswer,
          'GhostCopy did not answer. Update it to the latest version - older '
          'versions cannot be used from the command line.',
        );
      }
      final decoded = jsonDecode(reply);
      // Valid JSON of the wrong shape is as unreadable as invalid JSON.
      if (decoded is! Map<String, Object?>) throw const FormatException();
      return decoded;
    } on SocketException {
      // Connected, then lost: the app quit or restarted mid-request, perhaps
      // after the send had gone. Not "not running", which invites a retry.
      throw const AgentException(
        AgentError.connectionLost,
        'GhostCopy closed the connection before answering. It may still have '
        'sent this - check your history before trying again.',
      );
    } on TimeoutException {
      throw const AgentException(
        AgentError.timeout,
        'GhostCopy took too long to answer. It may still have sent this - '
        'check your history before trying again.',
      );
    } on FormatException {
      throw const AgentException(
        AgentError.badAnswer,
        'GhostCopy gave an answer this command does not understand.',
      );
    } finally {
      socket.destroy();
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
    }
  }
}
