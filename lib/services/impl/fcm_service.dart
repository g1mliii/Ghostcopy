import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../fcm_service.dart';

/// Concrete implementation of IFcmService
///
/// Manages FCM token lifecycle for mobile push notifications.
/// Desktop platforms should not use this service.
class FcmService implements IFcmService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  bool _initialized = false;

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
      _tokenRefreshSubscription = FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        debugPrint('[FcmService] 🔄 Token refreshed: ${newToken.substring(0, 20)}...');
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

      // Get the FCM token
      final token = await _messaging.getToken();

      if (token != null) {
        debugPrint('[FcmService] ✅ Got FCM token: ${token.substring(0, 20)}...');
      } else {
        debugPrint('[FcmService] ⚠️ FCM token is null');
      }

      return token;
    } on Exception catch (e) {
      debugPrint('[FcmService] ❌ Failed to get FCM token: $e');
      return null;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    _ensureInitialized();

    try {
      final settings = await _messaging.requestPermission();

      final granted = settings.authorizationStatus == AuthorizationStatus.authorized ||
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
