import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../desktop_push_service.dart';
import '../device_service.dart';

/// WNS for the packaged (Store) Windows build.
///
/// Talks to `com.ghostcopy.app/push` in the runner (push_channel.cpp), which
/// asks Windows for a channel URI and forwards every raw notification. The
/// unpackaged build has no package identity, so WNS refuses it and the
/// desktop stays on realtime.
class WindowsPushService implements IDesktopPushService {
  WindowsPushService({
    required this._deviceService,
    this._channel = const MethodChannel(channelName),
  });

  static const String channelName = 'com.ghostcopy.app/push';

  final IDeviceService _deviceService;
  final MethodChannel _channel;
  final StreamController<void> _pushes = StreamController<void>.broadcast();

  /// Channel URIs last 30 days, and the app can sit in the tray longer than
  /// that, so a fresh one is requested well before then.
  static const Duration _refreshEvery = Duration(days: 7);
  Timer? _refreshTimer;
  String? _channelUri;

  /// The URI last written to the device row, so a weekly refresh that gets
  /// the same channel back does not write it again.
  String? _storedUri;

  @override
  Stream<void> get pushes => _pushes.stream;

  @override
  Future<bool> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'received' && !_pushes.isClosed) _pushes.add(null);
    });
    final ok = await _createAndStore();
    if (ok) {
      _refreshTimer = Timer.periodic(_refreshEvery, (_) {
        unawaited(_createAndStore());
      });
    }
    return ok;
  }

  @override
  Future<void> reregister() async {
    final uri = _channelUri;
    if (uri == null) return;
    // The new account's row first: the update goes to whichever row
    // registration last returned.
    if (await _deviceService.registerCurrentDevice() &&
        await _deviceService.updateWnsChannelUri(uri)) {
      _storedUri = uri;
    }
  }

  Future<bool> _createAndStore() async {
    if (_pushes.isClosed) return false;
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'createChannel',
      );
      final uri = result?['uri'];
      if (uri is! String || uri.isEmpty) return false;
      _channelUri = uri;
      if (uri == _storedUri) return true;
      final stored = await _deviceService.updateWnsChannelUri(uri);
      if (stored) _storedUri = uri;
      return stored;
    } on PlatformException catch (e) {
      // "unpackaged" is the expected answer for a dev build.
      debugPrint('[WindowsPush] No WNS channel: ${e.code} ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _channel.setMethodCallHandler(null);
    unawaited(_pushes.close());
  }
}
