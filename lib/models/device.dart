/// Represents a registered device for a user
///
/// Devices are registered in Supabase to enable:
/// - Push notifications (mobile via FCM)
/// - Device management UI
/// - Active device tracking
class Device {
  const Device({
    required this.id,
    required this.userId,
    required this.deviceType,
    required this.lastActive,
    required this.createdAt,
    this.deviceName,
    this.fcmToken,
  });

  /// Create from JSON from Supabase
  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      deviceType: json['device_type'] as String,
      deviceName: json['device_name'] as String?,
      fcmToken: json['fcm_token'] as String?,
      lastActive: DateTime.parse(json['last_active'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  final String id;
  final String userId;
  final String deviceType; // 'windows', 'macos', 'android', 'ios', 'linux'
  final String? deviceName; // User-friendly name or hostname
  final String? fcmToken; // FCM token for mobile push notifications (null for desktop)
  final DateTime lastActive; // Last time device was active
  final DateTime createdAt;

  /// Convert to JSON for Supabase
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'device_type': deviceType,
      'device_name': deviceName,
      'fcm_token': fcmToken,
      'last_active': lastActive.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  /// Create a copy with updated fields
  Device copyWith({
    String? id,
    String? userId,
    String? deviceType,
    String? deviceName,
    String? fcmToken,
    DateTime? lastActive,
    DateTime? createdAt,
  }) {
    return Device(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      deviceType: deviceType ?? this.deviceType,
      deviceName: deviceName ?? this.deviceName,
      fcmToken: fcmToken ?? this.fcmToken,
      lastActive: lastActive ?? this.lastActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Device &&
        other.id == id &&
        other.userId == userId &&
        other.deviceType == deviceType &&
        other.deviceName == deviceName &&
        other.fcmToken == fcmToken &&
        other.lastActive == lastActive &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      userId,
      deviceType,
      deviceName,
      fcmToken,
      lastActive,
      createdAt,
    );
  }

  @override
  String toString() {
    return 'Device(id: $id, userId: $userId, deviceType: $deviceType, deviceName: $deviceName, fcmToken: ${fcmToken != null ? '[PRESENT]' : 'null'}, lastActive: $lastActive, createdAt: $createdAt)';
  }

  /// Check if device is a mobile device (Android or iOS)
  bool get isMobile => deviceType == 'android' || deviceType == 'ios';

  /// Check if device is a desktop device (Windows, macOS, Linux)
  bool get isDesktop =>
      deviceType == 'windows' || deviceType == 'macos' || deviceType == 'linux';

  /// Get a display name for the device
  String get displayName {
    if (deviceName != null && deviceName!.isNotEmpty) {
      return deviceName!;
    }

    // Fallback to capitalized device type
    return _capitalizeFirst(deviceType);
  }

  /// Capitalize first letter of a string
  String _capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }
}
