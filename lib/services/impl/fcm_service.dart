import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../fcm_service.dart';

/// Concrete implementation of IFcmService
///
/// Manages FCM token lifecycle for mobile push notifications.
/// Desktop platforms should not use this service.
class FcmService implements IFcmService {
  FcmService({
    FirebaseMessaging? messaging,
    bool? isIOS,
    Future<void> Function(Duration)? delay,
  }) : _messagingOverride = messaging,
       _isIOS = isIOS ?? Platform.isIOS,
       _delay = delay ?? Future<void>.delayed;

  final FirebaseMessaging? _messagingOverride;
  // Resolved on first use, so constructing the service does not touch
  // Firebase before Firebase.initializeApp.
  FirebaseMessaging get _messaging =>
      _messagingOverride ?? FirebaseMessaging.instance;
  final bool _isIOS;
  final Future<void> Function(Duration) _delay;
  bool _initialized = false;

  /// How long to wait for iOS to hand over the APNs token, and how many
  /// times to ask FCM before giving up until the next launch or resume.
  static const _apnsWait = Duration(milliseconds: 500);
  static const _apnsAttempts = 20;
  static const _tokenRetryDelays = [Duration(seconds: 2), Duration(seconds: 5)];

  // Stream controller for token refresh events
  final StreamController<String> _tokenRefreshController =
      StreamController<String>.broadcast();

  // Subscription for token refresh listener (must be cancelled to prevent memory leak)
  StreamSubscription<String>? _tokenRefreshSubscription;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('[FcmService] Already initialized, skipping');
      return;
    }

    try {
      debugPrint('[FcmService] Starting initialization...');

      // Listen for token refresh events (store subscription for cleanup)
      _tokenRefreshSubscription = _messaging.onTokenRefresh.listen((newToken) {
        // Length only. An FCM token is a credential for pushing to this
        // device, so it does not belong in logs - and substring(0, 20) threw
        // RangeError (an Error, which `on Exception` below would not catch) on
        // anything shorter.
        debugPrint(
          '[FcmService] 🔄 Token refreshed (${newToken.length} chars)',
        );
        _tokenRefreshController.add(newToken);
      });

      _initialized = true;
      debugPrint('[FcmService] ✅ Initialized successfully');
    } on Exception catch (e) {
      debugPrint('[FcmService] ❌ Failed to initialize: $e');
      rethrow;
    }
  }

  @override
  Future<String?> getToken() async {
    _ensureInitialized();

    try {
      // Request permissions first
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        debugPrint('[FcmService] ⚠️ Notification permissions not granted');
        return null;
      }

      // On iOS an FCM token exists only once APNs has given the app its
      // device token, which arrives a moment after permission is granted.
      // Asking before then fails (apns-token-not-set), and a first launch
      // asks straight after the permission prompt: the device registered with
      // no token and push stayed off until the next launch. Wait for it.
      if (_isIOS && !await _waitForApnsToken()) {
        debugPrint('[FcmService] ⚠️ No APNs token yet - asking FCM anyway');
      }

      // A network blip on a cold start cost the same. Retry briefly; a
      // failure after that is picked up by onTokenRefresh, or the next
      // resume's re-assert.
      for (var attempt = 0; ; attempt++) {
        try {
          final token = await _messaging.getToken();
          if (token != null && token.isNotEmpty) {
            debugPrint('[FcmService] ✅ Got FCM token (${token.length} chars)');
            return token;
          }
          debugPrint('[FcmService] ⚠️ FCM token is null');
        } on Exception catch (e) {
          debugPrint('[FcmService] ⚠️ FCM token attempt failed: $e');
        }
        if (attempt >= _tokenRetryDelays.length) return null;
        await _delay(_tokenRetryDelays[attempt]);
      }
    } on Exception catch (e) {
      debugPrint('[FcmService] ❌ Failed to get FCM token: $e');
      return null;
    }
  }

  /// Poll for the APNs token for up to [_apnsAttempts] x [_apnsWait].
  Future<bool> _waitForApnsToken() async {
    for (var i = 0; i < _apnsAttempts; i++) {
      try {
        if (await _messaging.getAPNSToken() != null) return true;
      } on Exception catch (e) {
        debugPrint('[FcmService] APNs token not readable yet: $e');
      }
      await _delay(_apnsWait);
    }
    return false;
  }

  @override
  Future<bool> requestPermissions() async {
    _ensureInitialized();

    try {
      final settings = await _messaging.requestPermission();

      final granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      if (granted) {
        debugPrint('[FcmService] ✅ Notification permissions granted');
      } else {
        debugPrint(
          '[FcmService] ❌ Notification permissions denied: ${settings.authorizationStatus}',
        );
      }

      return granted;
    } on Exception catch (e) {
      debugPrint('[FcmService] ❌ Failed to request permissions: $e');
      return false;
    }
  }

  @override
  Stream<String> get tokenRefreshStream => _tokenRefreshController.stream;

  @override
  void dispose() {
    debugPrint('[FcmService] Disposing service...');

    // Cancel token refresh subscription to prevent memory leak
    _tokenRefreshSubscription?.cancel();
    _tokenRefreshSubscription = null;

    _tokenRefreshController.close();
    _initialized = false;
    debugPrint('[FcmService] ✅ Disposed');
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('FcmService not initialized. Call initialize() first.');
    }
  }
}
