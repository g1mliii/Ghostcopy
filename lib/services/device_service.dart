import '../models/device.dart';

export '../models/device.dart';
export 'impl/device_service.dart';

/// Abstract interface for device registration and management
///
/// Handles:
/// - Registering current device in Supabase
/// - Querying user's registered devices
/// - Updating device activity timestamps
/// - Managing FCM tokens (mobile only)
abstract class IDeviceService {
  /// Register or update the current device
  ///
  /// Should be called on app startup after authentication.
  /// Updates last_active timestamp if device already exists.
  Future<void> registerCurrentDevice();

  /// Get all devices registered for the current user
  ///
  /// Returns list of devices sorted by last_active (newest first).
  /// Throws if user is not authenticated.
  ///
  /// [forceRefresh] bypasses cache and fetches fresh data from server.
  Future<List<Device>> getUserDevices({bool forceRefresh = false});

  /// Update the FCM token for the current device
  ///
  /// Only applicable for mobile devices (Android/iOS).
  /// Desktop devices don't use FCM tokens.
  Future<void> updateFcmToken(String fcmToken);

  /// Update last active timestamp for current device
  ///
  /// Can be called periodically to track device activity.
  Future<void> updateLastActive();

  /// Remove the current device from registered devices
  ///
  /// Useful when user logs out or uninstalls app.
  Future<void> unregisterCurrentDevice();

  /// Update the name of a specific device
  ///
  /// Returns true if update was successful, false otherwise.
  Future<bool> updateDeviceName(String deviceId, String name);

  /// Remove a specific device by ID
  ///
  /// Returns true if removal was successful, false otherwise.
  /// Cannot remove the current device - use unregisterCurrentDevice instead.
  Future<bool> removeDevice(String deviceId);

  /// Get the current device ID
  ///
  /// Returns null if device hasn't been registered yet.
  String? getCurrentDeviceId();

  /// Initialize the service
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
