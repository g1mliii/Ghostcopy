import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import '../hotkey_service.dart';

/// Compositor-owned global shortcuts, including while XWayland is unfocused.
/// KDE owns the actual binding; Settings opens its shortcut configuration UI.
class LinuxHotkeyService implements IHotkeyService {
  LinuxHotkeyService({DBusClient? client})
    : _client = client ?? DBusClient.session();

  static const _destination = 'org.freedesktop.portal.Desktop';
  static const _interface = 'org.freedesktop.portal.GlobalShortcuts';
  static final _path = DBusObjectPath('/org/freedesktop/portal/desktop');
  final DBusClient _client;
  final Map<HotKey, (DBusObjectPath, VoidCallback)> _bindings = {};
  final Map<HotKey, Future<void>> _registrations = {};
  final Map<DBusObjectPath, Completer<DBusSignal>> _requests = {};
  StreamSubscription<DBusSignal>? _activated;
  HotKey? _lastRequested;
  VoidCallback? _lastCallback;
  int _serial = 0;
  bool _disposed = false;

  @override
  Future<void> registerHotkey(HotKey hotkey, VoidCallback callback) async {
    final pending = _registrations[hotkey];
    if (pending != null) return pending;
    final operation = _register(hotkey, callback);
    _registrations[hotkey] = operation;
    try {
      await operation;
    } finally {
      _registrations.removeWhere((key, value) => key == hotkey);
    }
  }

  Future<void> _register(HotKey hotkey, VoidCallback callback) async {
    if (_disposed) throw const FormatException('Shortcut service is closed');
    final trigger = preferredTrigger(hotkey);
    _lastRequested = hotkey;
    _lastCallback = callback;
    final existing = _bindings[hotkey];
    if (existing != null) {
      _bindings[hotkey] = (existing.$1, callback);
      return;
    }
    await _client.listNames().timeout(const Duration(seconds: 5));
    // Resolve before signal subscription; also starts the portal if needed.
    final portal = DBusRemoteObject(_client, name: _destination, path: _path);
    await portal
        .getProperty(_interface, 'version')
        .timeout(const Duration(seconds: 5));
    if (_disposed) throw const FormatException('Shortcut service is closed');
    _activated ??=
        DBusSignalStream(
          _client,
          sender: _destination,
          path: _path,
          interface: _interface,
          name: 'Activated',
          signature: DBusSignature('osta{sv}'),
        ).listen(
          (signal) {
            if (_disposed || signal.values[1].asString() != 'spotlight') return;
            for (final binding in _bindings.values.toList()) {
              if (binding.$1 == signal.values[0]) binding.$2();
            }
          },
          onError: (Object error) {
            debugPrint('[LinuxHotkey] Activation failed: $error');
          },
        );

    final sessionToken = 'ghostcopy_${pid}_${_serial++}';
    DBusObjectPath? session;
    var retained = false;
    try {
      final created = await _request('CreateSession', [], {
        'session_handle_token': DBusString(sessionToken),
      });
      session = DBusObjectPath(created['session_handle']!.asString());
      if (_disposed) throw const FormatException('Shortcut service is closed');
      final result = await _request('BindShortcuts', [
        session,
        DBusArray(DBusSignature('(sa{sv})'), [
          DBusStruct([
            const DBusString('spotlight'),
            DBusDict.stringVariant({
              'description': const DBusString('Open GhostCopy'),
              'preferred_trigger': DBusString(trigger),
            }),
          ]),
        ]),
        const DBusString(''),
      ], {});
      final bound =
          result['shortcuts']?.asArray().any(
            (value) => value.asStruct().first.asString() == 'spotlight',
          ) ??
          false;
      if (!bound || _disposed) {
        throw const FormatException('Global shortcut was not granted');
      }
      _bindings[hotkey] = (session, callback);
      retained = true;
    } finally {
      if (!retained && session != null) await _closeSession(session);
    }
  }

  /// XDG preferred trigger syntax, as opposed to GTK accelerator syntax.
  @visibleForTesting
  static String preferredTrigger(HotKey hotkey) {
    final key = hotkey.key.toLowerCase();
    final named = <String, String>{
      'enter': 'Return',
      'escape': 'Escape',
      'tab': 'Tab',
      'backspace': 'BackSpace',
      'delete': 'Delete',
      'insert': 'Insert',
      'home': 'Home',
      'end': 'End',
      'pageup': 'Prior',
      'pagedown': 'Next',
      'arrowup': 'Up',
      'arrowdown': 'Down',
      'arrowleft': 'Left',
      'arrowright': 'Right',
      'space': 'space',
    };
    final symbol =
        named[key] ??
        (RegExp(r'^f([1-9]|1[0-2])$').hasMatch(key) ? key.toUpperCase() : key);
    if (!named.containsKey(key) &&
        !RegExp(r'^([a-z0-9]|f([1-9]|1[0-2]))$').hasMatch(key)) {
      throw UnsupportedHotkeyException(key);
    }
    return [
      if (hotkey.ctrl) 'CTRL',
      if (hotkey.alt) 'ALT',
      if (hotkey.shift) 'SHIFT',
      if (hotkey.meta) 'LOGO',
      symbol,
    ].join('+');
  }

  Future<Map<String, DBusValue>> _request(
    String method,
    List<DBusValue> arguments,
    Map<String, DBusValue> options,
  ) async {
    final token = 'ghostcopy_${pid}_${_serial++}';
    final sender = _client.uniqueName.substring(1).replaceAll('.', '_');
    final requestPath = DBusObjectPath(
      '/org/freedesktop/portal/desktop/request/$sender/$token',
    );
    final response = Completer<DBusSignal>();
    _requests[requestPath] = response;
    final subscription =
        DBusSignalStream(
          _client,
          sender: _destination,
          path: requestPath,
          interface: 'org.freedesktop.portal.Request',
          name: 'Response',
          signature: DBusSignature('ua{sv}'),
        ).listen(
          (signal) {
            if (!response.isCompleted) response.complete(signal);
          },
          onError: (Object error, StackTrace stack) {
            if (!response.isCompleted) response.completeError(error, stack);
          },
        );
    var finished = false;
    try {
      // Listen before making the call: a portal may reply immediately. Wait
      // for both futures together so neither can produce an unhandled error.
      final results = await Future.wait<Object>([
        _client.callMethod(
          destination: _destination,
          path: _path,
          interface: _interface,
          name: method,
          values: [
            ...arguments,
            DBusDict.stringVariant({
              ...options,
              'handle_token': DBusString(token),
            }),
          ],
          replySignature: DBusSignature('o'),
        ),
        response.future,
      ], eagerError: true).timeout(const Duration(minutes: 2));
      final signal = results[1] as DBusSignal;
      finished = true;
      if (signal.values[0].asUint32() != 0) {
        throw const FormatException('Global shortcut request was cancelled');
      }
      return signal.values[1].asStringVariantDict();
    } finally {
      _requests.remove(requestPath);
      await subscription.cancel();
      if (!finished) {
        await _closeObject(requestPath, 'org.freedesktop.portal.Request');
      }
    }
  }

  /// Let KDE display the real binding, including changes made outside the app.
  Future<void> configure() async {
    if (_bindings.isEmpty && _lastRequested != null && _lastCallback != null) {
      await registerHotkey(_lastRequested!, _lastCallback!);
      return;
    }
    final session = _bindings.values.firstOrNull?.$1;
    if (session != null) {
      final portal = DBusRemoteObject(_client, name: _destination, path: _path);
      final version = await portal.getProperty(_interface, 'version');
      if (version.asUint32() >= 2) {
        await portal.callMethod(_interface, 'ConfigureShortcuts', [
          session,
          const DBusString(''),
          DBusDict.stringVariant({}),
        ]);
        return;
      }
    }
    // Older KDE portal versions expose configuration in System Settings.
    await Process.start('systemsettings', [
      'kcm_keys',
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> unregisterHotkey(HotKey hotkey) async {
    final binding = _bindings.remove(hotkey);
    if (binding != null) await _closeSession(binding.$1);
  }

  Future<void> _closeSession(DBusObjectPath session) =>
      _closeObject(session, 'org.freedesktop.portal.Session');

  Future<void> _closeObject(DBusObjectPath path, String interface) async {
    try {
      await _client
          .callMethod(
            destination: _destination,
            path: path,
            interface: interface,
            name: 'Close',
            values: [],
          )
          .timeout(const Duration(seconds: 3));
    } on Exception catch (error) {
      debugPrint('[LinuxHotkey] Close failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final request in _requests.values.toList()) {
      if (!request.isCompleted) {
        request.completeError(
          const FormatException('Shortcut service is closed'),
        );
      }
    }
    await _activated?.cancel();
    for (final binding in _bindings.values.toList()) {
      await _closeSession(binding.$1);
    }
    _bindings.clear();
    await _client.close();
  }
}
