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

/// The loopback port the running app listens on. Shared with SingleInstance.
const int agentPort = 47821;

/// Sent first, so the app can tell GhostCopy from an unrelated process that
/// happens to hold the port, and the other way round.
const String agentHandshakeMagic = 'ghostcopy/1';

/// The device types a clip can be addressed to.
const List<String> deviceTypes = ['windows', 'macos', 'android', 'ios'];

/// Friendlier names an agent or a person is likely to use.
const Map<String, List<String>> deviceAliases = {
  'phone': ['android', 'ios'],
  'mobile': ['android', 'ios'],
  'iphone': ['ios'],
  'desktop': ['windows', 'macos'],
  'computer': ['windows', 'macos'],
  'mac': ['macos'],
  'pc': ['windows'],
};

/// Turn what the caller asked for into device types, or throw a
/// [FormatException] naming what was not understood. Empty in, empty out -
/// which means "the user's default", not "nowhere".
List<String> resolveDeviceTargets(Iterable<String> requested) {
  final resolved = <String>{};
  for (final raw in requested) {
    final name = raw.trim().toLowerCase();
    if (name.isEmpty) continue;
    if (deviceTypes.contains(name)) {
      resolved.add(name);
    } else if (deviceAliases.containsKey(name)) {
      resolved.addAll(deviceAliases[name]!);
    } else {
      throw FormatException(
        'Unknown device "$raw". Use one of: '
        '${[...deviceAliases.keys, ...deviceTypes].join(', ')}.',
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
  const file = 'single_instance.secret';
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
    this.port = agentPort,
    String? secretPath,
    this.timeout = const Duration(seconds: 60),
  }) : secretPath = secretPath ?? defaultSecretPath();

  final int port;
  final String secretPath;

  /// Long enough for a 10 MB upload on a slow connection.
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
      throw const AgentException(
        'not_running',
        'GhostCopy is not running. Open it, then try again.',
      );
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
      if (reply.trim().isEmpty) {
        throw const AgentException(
          'no_answer',
          'GhostCopy did not answer. Update it to the latest version - older '
              'versions cannot be used from the command line.',
        );
      }
      final decoded = jsonDecode(reply);
      if (decoded is! Map<String, Object?>) {
        throw const AgentException(
          'bad_answer',
          'GhostCopy gave an answer '
              'this command does not understand.',
        );
      }
      return decoded;
    } on TimeoutException {
      throw const AgentException(
        'timeout',
        'GhostCopy took too long to answer.',
      );
    } on FormatException {
      throw const AgentException(
        'bad_answer',
        'GhostCopy gave an answer this '
            'command does not understand.',
      );
    } finally {
      socket.destroy();
    }
  }

  Future<String> _readSecret() async {
    final file = File(secretPath);
    if (!file.existsSync()) {
      throw const AgentException(
        'not_installed',
        'GhostCopy has not run on this computer yet. Install and open it '
            'first.',
      );
    }
    return (await file.readAsString()).trim();
  }
}
