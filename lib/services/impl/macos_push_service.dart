// The Firebase options below are build configuration: they come from a
// gitignored file (the iOS GoogleService-Info.plist) and have no runtime
// source in a Developer ID build, so --dart-define is the way in.
// ignore_for_file: do_not_use_environment

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../desktop_push_service.dart';
import '../device_service.dart';
import 'fcm_service.dart';

/// Firebase options for the macOS build, passed with --dart-define at build
/// time (installer/macos/build-release.sh reads them from the iOS
/// GoogleService-Info.plist: the Mac app shares its bundle id, so it uses the
/// same Firebase app and the same APNs key). Without them push is off and
/// the Mac stays on realtime.
const String _apiKey = String.fromEnvironment('GHOSTCOPY_FIREBASE_API_KEY');
const String _appId = String.fromEnvironment('GHOSTCOPY_FIREBASE_APP_ID');
const String _senderId = String.fromEnvironment('GHOSTCOPY_FIREBASE_SENDER_ID');
const String _projectId = String.fromEnvironment(
  'GHOSTCOPY_FIREBASE_PROJECT_ID',
);

bool get macPushConfigured =>
    _apiKey.isNotEmpty &&
    _appId.isNotEmpty &&
    _senderId.isNotEmpty &&
    _projectId.isNotEmpty;

/// Silent pushes that land while the app is not frontmost - which is nearly
/// always, for a tray app. On macOS the plugin delivers those through the
/// background handler, in this same isolate (FLTFirebaseMessagingPlugin
/// checks NSApplication.isActive), so this can reach the live service.
final StreamController<void> _backgroundPushes =
    StreamController<void>.broadcast();

@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {
  if (!_backgroundPushes.isClosed) _backgroundPushes.add(null);
}

/// FCM (APNs underneath) for the macOS build.
class MacPushService implements IDesktopPushService {
  MacPushService({required this._deviceService});

  /// MainFlutterWindow.swift; registers the app with APNs.
  static const MethodChannel _nativeChannel = MethodChannel(
    'com.ghostcopy.app/push',
  );

  final IDeviceService _deviceService;
  final StreamController<void> _pushes = StreamController<void>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  FcmService? _fcm;
  String? _token;

  @override
  Stream<void> get pushes => _pushes.stream;

  @override
  Future<bool> start() async {
    if (!macPushConfigured) {
      debugPrint('[MacPush] Firebase not configured for this build');
      return false;
    }
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: const FirebaseOptions(
            apiKey: _apiKey,
            appId: _appId,
            messagingSenderId: _senderId,
            projectId: _projectId,
          ),
        );
      }
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
      // Silent pushes to a backgrounded app arrive here, from AppDelegate:
      // firebase_messaging's own path did not deliver them on macOS.
      _nativeChannel.setMethodCallHandler((call) async {
        if (call.method == 'remoteNotification')
          _wake('native ${call.arguments}');
      });
      // Now that Firebase exists to receive the APNs token. The plugin's own
      // launch-time registration ran before it did, and skipped.
      await _nativeChannel.invokeMethod<void>('registerForRemoteNotifications');

      // Waits for the APNs token the same way iOS does: an FCM token exists
      // only once APNs has handed one over. No permission prompt: these
      // pushes are silent, and a user who turned GhostCopy's notifications
      // off should still get them.
      final fcm = _fcm = FcmService(isIOS: true);
      await fcm.initialize();
      final token = await fcm.getToken(requirePermission: false);
      if (token == null) return false;
      _token = token;

      _subscriptions
        ..add(FirebaseMessaging.onMessage.listen((_) => _wake('foreground')))
        ..add(_backgroundPushes.stream.listen((_) => _wake('background')))
        ..add(
          // registerCurrentDevice rather than updateFcmToken, as on mobile
          // (main.dart): it upserts the row, so a refresh that lands before
          // or after an account switch still reaches the signed-in row.
          fcm.tokenRefreshStream.listen((fresh) {
            _token = fresh;
            unawaited(_deviceService.registerCurrentDevice(fcmToken: fresh));
          }),
        );

      return await _deviceService.registerCurrentDevice(fcmToken: token);
    } on Exception catch (e) {
      debugPrint('[MacPush] Push unavailable: $e');
      return false;
    }
  }

  void _wake(String via) {
    debugPrint('[MacPush] Push received ($via)');
    if (!_pushes.isClosed) _pushes.add(null);
  }

  @override
  Future<void> reregister() async {
    final token = _token;
    if (token != null) {
      await _deviceService.registerCurrentDevice(fcmToken: token);
    }
  }

  @override
  void dispose() {
    _nativeChannel.setMethodCallHandler(null);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _fcm?.dispose();
    unawaited(_pushes.close());
  }
}
