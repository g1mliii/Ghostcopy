export 'impl/fcm_service.dart';

/// Abstract interface for Firebase Cloud Messaging token management
///
/// Handles:
/// - Getting FCM token from Firebase
/// - Listening for token refresh events
/// - Requesting notification permissions
abstract class IFcmService {
  /// Get the current FCM token
  ///
  /// Returns null if permissions not granted or token not available.
  /// Automatically requests notification permissions if not already granted.
  Future<String?> getToken();

  /// Request notification permissions from user
  ///
  /// Returns true if permissions granted, false otherwise.
  Future<bool> requestPermissions();

  /// Stream of FCM token updates
  ///
  /// Emits new tokens when they are refreshed by Firebase.
  /// You should listen to this and update the token in Supabase.
  Stream<String> get tokenRefreshStream;

  /// Initialize the service
  ///
  /// Must be called after Firebase.initializeApp().
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
