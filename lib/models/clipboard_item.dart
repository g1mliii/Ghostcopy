/// Represents a clipboard item stored in the synchronization history
class ClipboardItem {
  const ClipboardItem({
    required this.id,
    required this.userId,
    required this.content,
    required this.deviceType,
    required this.createdAt,
    this.deviceName,
    this.targetDeviceType,
    this.isPublic = false,
  });

  /// Create from JSON from Supabase
  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    return ClipboardItem(
      id: json['id'].toString(),
      userId: json['user_id'] as String,
      content: json['content'] as String,
      deviceName: json['device_name'] as String?,
      deviceType: json['device_type'] as String,
      targetDeviceType: json['target_device_type'] as String?,
      isPublic: json['is_public'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  final String id;
  final String userId;
  final String content;
  final String? deviceName;
  final String deviceType; // sender's device type: 'windows', 'macos', 'android', 'ios'
  final String? targetDeviceType; // target device type filter: null = all devices, specific = only that type
  final bool isPublic;
  final DateTime createdAt;

  /// Convert to JSON for Supabase
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'content': content,
      'device_name': deviceName,
      'device_type': deviceType,
      'target_device_type': targetDeviceType,
      'is_public': isPublic,
      'created_at': createdAt.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ClipboardItem &&
        other.id == id &&
        other.userId == userId &&
        other.content == content &&
        other.deviceName == deviceName &&
        other.deviceType == deviceType &&
        other.targetDeviceType == targetDeviceType &&
        other.isPublic == isPublic &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      userId,
      content,
      deviceName,
      deviceType,
      targetDeviceType,
      isPublic,
      createdAt,
    );
  }

  @override
  String toString() {
    return 'ClipboardItem(id: $id, userId: $userId, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}..., deviceName: $deviceName, deviceType: $deviceType, targetDeviceType: $targetDeviceType, isPublic: $isPublic, createdAt: $createdAt)';
  }
}
