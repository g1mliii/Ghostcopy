import 'package:flutter/foundation.dart';
import 'package:ghostcopy_agent/agent_protocol.dart';
import '../models/clipboard_item.dart';
import '../models/exceptions.dart';
import '../repositories/clipboard_repository.dart';
import '../utils/network_errors.dart';
import 'account_prompt_store.dart';
import 'auth_service.dart';
import 'device_service.dart';
import 'settings_service.dart';

/// Sends a file at a path, as Explorer's "Send with GhostCopy" and the macOS
/// service do. [targets] null means the user's default devices.
typedef SendFileAtPath =
    Future<({bool ok, String message})> Function(
      String path,
      List<String>? targets,
    );

/// Runs what the `ghostcopy` command line and its MCP server ask for, inside
/// the running app, with its session. See packages/ghostcopy_agent.
///
/// Answers are what the command line prints: `ok`, a stable `error` code, and
/// a `message` for a person. A send reports "sent" - the clip reached the
/// server - never "received", which nothing here can know.
class AgentCommandHandler {
  AgentCommandHandler({
    required IAuthService authService,
    required IClipboardRepository clipboardRepository,
    required IDeviceService deviceService,
    required ISettingsService settingsService,
    required this._sendFile,
    AccountPromptStore? accountPromptStore,
  }) : _auth = authService,
       _clips = clipboardRepository,
       _devices = deviceService,
       _settings = settingsService,
       _accountPrompts = accountPromptStore;

  final IAuthService _auth;
  final IClipboardRepository _clips;
  final IDeviceService _devices;
  final ISettingsService _settings;
  final SendFileAtPath _sendFile;

  /// Counts a successful send toward the guest account offer, as every other
  /// way of sending does. The file path records its own.
  final AccountPromptStore? _accountPrompts;

  Future<Map<String, Object?>> handle(Map<String, Object?> command) async {
    if (!await _settings.getAgentAccessEnabled()) {
      return _refused(
        'disabled',
        'The command line is turned off. In GhostCopy, open Settings and turn '
            'on "Command line & AI tools".',
      );
    }
    final userId = _auth.currentUserId;
    if (userId == null) {
      return _refused(
        'signed_out',
        'GhostCopy is not signed in. Open it and sign in first.',
      );
    }

    final List<String> requested;
    try {
      final to = command['to'];
      requested = resolveDeviceTargets(
        to is List ? to.whereType<String>() : const [],
      );
    } on FormatException catch (e) {
      return _refused('bad_request', e.message);
    }

    switch (command['name']) {
      case 'send_text':
        return _sendText(userId, command['text'], requested);
      case 'send_file':
        return _sendFileCommand(command['path'], requested);
      case 'list_devices':
        return _listDevices();
      default:
        return _refused(
          'bad_request',
          'Unknown command "${command['name']}". Update the ghostcopy command '
              'to match this app.',
        );
    }
  }

  Future<Map<String, Object?>> _sendText(
    String userId,
    Object? text,
    List<String> requested,
  ) async {
    if (text is! String || text.trim().isEmpty) {
      return _refused('bad_request', 'Nothing to send: the text is empty.');
    }
    final targets = await _targets(requested);
    try {
      await _clips.insert(
        ClipboardItem(
          id: '0', // Supabase generates it
          userId: userId,
          content: text,
          deviceName: ClipboardRepository.getCurrentDeviceName(),
          deviceType: ClipboardRepository.getCurrentDeviceType(),
          targetDeviceTypes: targets,
          createdAt: DateTime.now(),
        ),
      );
    } on ValidationException catch (e) {
      return _refused('bad_request', e.message);
    } on SecurityException catch (e) {
      return _refused('bad_request', e.message);
    } on Exception catch (e) {
      return _failed(sendFailureMessage(e, 'The send failed: $e'));
    }
    // Best effort: the clip has gone. A failed write here reported as a
    // failed send would invite a retry, and a second copy of the clip.
    try {
      await _accountPrompts?.recordSend();
    } on Exception catch (e) {
      debugPrint('[Agent] Could not record the send: $e');
    }
    return {
      'ok': true,
      'status': 'sent',
      'to': targets ?? 'all',
      'message': 'Sent to ${_describe(targets)}.',
    };
  }

  Future<Map<String, Object?>> _sendFileCommand(
    Object? path,
    List<String> requested,
  ) async {
    if (path is! String || path.trim().isEmpty) {
      return _refused('bad_request', 'No file given.');
    }
    final targets = await _targets(requested);
    final result = await _sendFile(path, targets);
    if (!result.ok) return _failed(result.message);
    return {
      'ok': true,
      'status': 'sent',
      'to': targets ?? 'all',
      'message': result.message,
    };
  }

  Future<Map<String, Object?>> _listDevices() async {
    final here = _devices.getCurrentDeviceId();
    final devices = await _devices.fetchUserDevices();
    // Null is a failed fetch. Saying "no devices" for it would have callers
    // target on false data; an empty list is an account with none.
    if (devices == null) {
      return _failed(
        'Could not load your devices. Check your connection and try again.',
      );
    }
    return {
      'ok': true,
      'devices': [
        for (final device in devices)
          {
            'name': device.deviceName,
            'type': device.deviceType,
            'this_device': device.id == here,
            'last_active': device.lastActive.toUtc().toIso8601String(),
          },
      ],
    };
  }

  /// What was asked for, else the "Send to devices" setting. Null is every
  /// device, which is also what an empty setting means.
  Future<List<String>?> _targets(List<String> requested) async {
    if (requested.isNotEmpty) return requested;
    final defaults = await _settings.getAutoSendTargetDevices();
    return defaults.isEmpty ? null : defaults.toList();
  }

  static String _describe(List<String>? targets) {
    if (targets == null) return 'all your devices';
    const names = {
      'ios': 'iPhone',
      'android': 'Android',
      'macos': 'Mac',
      'windows': 'Windows',
      'linux': 'Linux',
    };
    return targets.map((t) => names[t] ?? t).join(', ');
  }

  static Map<String, Object?> _refused(String code, String message) => {
    'ok': false,
    'error': code,
    'message': message,
  };

  static Map<String, Object?> _failed(String message) => {
    'ok': false,
    'error': 'send_failed',
    'message': message,
  };
}
