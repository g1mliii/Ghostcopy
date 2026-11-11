import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'clipboard_sync_service.dart';
import 'lifecycle_controller.dart';

/// OS push for a desktop: FCM on macOS, WNS on Windows.
///
/// A phone learns of a clip by push. A desktop learned by holding a realtime
/// websocket open all day, one Supabase connection per running desktop. Both
/// macOS and Windows keep a push connection of their own for every app on
/// the machine, so a desktop in the tray can be woken the same way. The push
/// carries only a row id; what arrived is fetched by the usual poll.
abstract class IDesktopPushService {
  /// Register with the OS push service and store the token on this device's
  /// row. False when push is not available here - no package identity, no
  /// Firebase configuration, permission refused, or the request failed. The
  /// desktop then simply keeps its realtime connection.
  Future<bool> start();

  /// Store the token again, for a different signed-in account.
  Future<void> reregister();

  /// One event per push received.
  Stream<void> get pushes;

  void dispose();
}

/// Ties a working push to the connection it can replace.
///
/// Push is trusted only once it has been seen to work: the first push to
/// arrive proves the token, the server credentials and the routing all at
/// once, and only then does [ILifecycleController.desktopPushActive] let the
/// tray close realtime. A clip the tray health check finds without a push
/// shortly before it means push has stopped reaching this desktop, so trust
/// is withdrawn and realtime reopens until a push arrives again.
class DesktopPushCoordinator {
  DesktopPushCoordinator({
    required this._push,
    required this._sync,
    required this._lifecycle,
  });

  final IDesktopPushService _push;
  final IClipboardSyncService _sync;
  final ILifecycleController _lifecycle;

  StreamSubscription<void>? _subscription;
  void Function()? _previousOnPollFoundClip;
  DateTime? _lastPushAt;
  Timer? _missedPushTimer;

  /// How long a clip the poll found may still be followed by its push
  /// before push counts as missing. Apple and Microsoft can hold a push
  /// for seconds, and the health poll can land in between.
  @visibleForTesting
  static const Duration lateGrace = Duration(seconds: 30);

  /// How recent a push must be for a clip a poll finds to count as
  /// announced. The push-triggered poll lands within seconds; this allows
  /// for a slow fetch.
  @visibleForTesting
  static const Duration announcedWindow = Duration(minutes: 2);

  Future<bool> start() async {
    final started = await _push.start();
    if (!started) return false;
    _subscription = _push.pushes.listen((_) => _onPush());
    final previous = _previousOnPollFoundClip = _sync.onPollFoundClip;
    _sync.onPollFoundClip = () {
      previous?.call();
      _onPollFoundClip();
    };
    return true;
  }

  void _onPush() {
    _missedPushTimer?.cancel();
    _missedPushTimer = null;
    _lastPushAt = clock.now();
    _lifecycle.desktopPushActive = true;
    _sync.checkForNewClips();
  }

  void _onPollFoundClip() {
    if (!_lifecycle.desktopPushActive) return;
    final last = _lastPushAt;
    if (last != null && clock.now().difference(last) <= announcedWindow) {
      return;
    }
    // Give a late push the chance to arrive before calling it missing.
    _missedPushTimer ??= Timer(lateGrace, () {
      _missedPushTimer = null;
      debugPrint(
        '[DesktopPush] A clip arrived without a push - reopening realtime',
      );
      _lifecycle.desktopPushActive = false;
    });
  }

  void dispose() {
    _missedPushTimer?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    _sync.onPollFoundClip = _previousOnPollFoundClip;
    _lifecycle.desktopPushActive = false;
    _push.dispose();
  }
}
