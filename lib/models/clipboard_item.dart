/// Represents a clipboard item stored in the synchronization history
class ClipboardItem {
  const ClipboardItem({
    required this.id,
    required this.userId,
    required this.content,
    required this.deviceType,
    required this.createdAt,
    this.deviceName,
    this.targetDeviceTypes,
    this.isPublic = false,
    this.isEncrypted = false,
  });

  /// Create from JSON from Supabase
  factory ClipboardItem.fromJson(Map<String, dynamic> json) {
    // Parse target_device_type which can be null, a list, or a single string
    List<String>? targetDeviceTypes;
    final targetDeviceTypeJson = json['target_device_type'];
    if (targetDeviceTypeJson != null) {
      if (targetDeviceTypeJson is List) {
        targetDeviceTypes = List<String>.from(targetDeviceTypeJson);
      } else if (targetDeviceTypeJson is String) {
        // Handle old single-value format for backwards compatibility
        targetDeviceTypes = [targetDeviceTypeJson];
      }
    }

    return ClipboardItem(
      id: json['id'].toString(),
      userId: json['user_id'] as String,
      content: json['content'] as String,
      deviceName: json['device_name'] as String?,
      deviceType: json['device_type'] as String,
      targetDeviceTypes: targetDeviceTypes,
      isPublic: json['is_public'] as bool? ?? false,
      isEncrypted: json['is_encrypted'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  final String id;
  final String userId;
  final String content;
  final String? deviceName;
  final String deviceType; // sender's device type: 'windows', 'macos', 'android', 'ios'
  final List<String>? targetDeviceTypes; // target device types filter: null = all devices, list = only those types
  final bool isPublic;
  final bool isEncrypted; // true if content is encrypted with user passphrase
  final DateTime createdAt;

  /// Convert to JSON for Supabase
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'content': content,
      'device_name': deviceName,
      'device_type': deviceType,
      'target_device_type': targetDeviceTypes,
      'is_public': isPublic,
      'is_encrypted': isEncrypted,
      'created_at': createdAt.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    // Helper to compare lists
    bool listEquals<T>(List<T>? a, List<T>? b) {
      if (a == null) return b == null;
      if (b == null || a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    return other is ClipboardItem &&
        other.id == id &&
        other.userId == userId &&
        other.content == content &&
        other.deviceName == deviceName &&
        other.deviceType == deviceType &&
        listEquals(other.targetDeviceTypes, targetDeviceTypes) &&
        other.isPublic == isPublic &&
        other.isEncrypted == isEncrypted &&
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
      Object.hashAll(targetDeviceTypes ?? []),
      isPublic,
      isEncrypted,
      createdAt,
    );
  }

  @override
  String toString() {
    return 'ClipboardItem(id: $id, userId: $userId, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}..., deviceName: $deviceName, deviceType: $deviceType, targetDeviceTypes: $targetDeviceTypes, isPublic: $isPublic, isEncrypted: $isEncrypted, createdAt: $createdAt)';
  }
}
