/// Content types supported by clipboard
enum ContentType {
  text('text'),
  html('html'),
  markdown('markdown'),
  imagePng('image_png'),
  imageJpeg('image_jpeg'),
  imageGif('image_gif');

  const ContentType(this.value);
  final String value;

  bool get isImage => this == imagePng || this == imageJpeg || this == imageGif;
  bool get isRichText => this == html || this == markdown;
  bool get requiresStorage => isImage;

  static ContentType fromString(String value) {
    return ContentType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => ContentType.text,
    );
  }
}

/// Rich text format
enum RichTextFormat {
  html('html'),
  markdown('markdown');

  const RichTextFormat(this.value);
  final String value;

  static RichTextFormat? fromString(String? value) {
    if (value == null) return null;
    return RichTextFormat.values.firstWhere(
      (e) => e.value == value,
      orElse: () => RichTextFormat.html,
    );
  }
}

/// Metadata for clipboard items (images, rich text)
class ClipboardMetadata {
  const ClipboardMetadata({
    this.width,
    this.height,
    this.thumbnailUrl,
    this.originalFilename,
  });

  factory ClipboardMetadata.fromJson(Map<String, dynamic> json) {
    return ClipboardMetadata(
      width: json['width'] as int?,
      height: json['height'] as int?,
      thumbnailUrl: json['thumbnail_url'] as String?,
      originalFilename: json['original_filename'] as String?,
    );
  }

  final int? width;
  final int? height;
  final String? thumbnailUrl;
  final String? originalFilename;

  Map<String, dynamic> toJson() => {
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (thumbnailUrl != null) 'thumbnail_url': thumbnailUrl,
        if (originalFilename != null) 'original_filename': originalFilename,
      };

  @override
  bool operator ==(Object other) =>
      other is ClipboardMetadata &&
      other.width == width &&
      other.height == height &&
      other.thumbnailUrl == thumbnailUrl &&
      other.originalFilename == originalFilename;

  @override
  int get hashCode => Object.hash(width, height, thumbnailUrl, originalFilename);
}

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
    this.contentType = ContentType.text,
    this.storagePath,
    this.fileSizeBytes,
    this.mimeType,
    this.metadata,
    this.richTextFormat,
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
      contentType: ContentType.fromString(
        json['content_type'] as String? ?? 'text',
      ),
      storagePath: json['storage_path'] as String?,
      fileSizeBytes: json['file_size_bytes'] as int?,
      mimeType: json['mime_type'] as String?,
      metadata: json['metadata'] != null
          ? ClipboardMetadata.fromJson(json['metadata'] as Map<String, dynamic>)
          : null,
      richTextFormat: RichTextFormat.fromString(
        json['rich_text_format'] as String?,
      ),
    );
  }

  final String id;
  final String userId;
  final String content; // Text content OR storage URL for images
  final String? deviceName;
  final String deviceType; // sender's device type: 'windows', 'macos', 'android', 'ios'
  final List<String>? targetDeviceTypes; // target device types filter: null = all devices, list = only those types
  final bool isPublic;
  final bool isEncrypted; // true if content is encrypted with user passphrase
  final DateTime createdAt;

  // New fields for multi-format support
  final ContentType contentType;
  final String? storagePath; // Supabase Storage path for images
  final int? fileSizeBytes;
  final String? mimeType;
  final ClipboardMetadata? metadata;
  final RichTextFormat? richTextFormat;

  // Helper methods
  bool get isImage => contentType.isImage;
  bool get isRichText => contentType.isRichText;
  bool get requiresDownload => contentType.requiresStorage;

  String get displaySize {
    if (fileSizeBytes == null) return '';
    if (fileSizeBytes! < 1024) return '${fileSizeBytes}B';
    if (fileSizeBytes! < 1048576) {
      return '${(fileSizeBytes! / 1024).toStringAsFixed(1)}KB';
    }
    return '${(fileSizeBytes! / 1048576).toStringAsFixed(1)}MB';
  }

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
      'content_type': contentType.value,
      'storage_path': storagePath,
      'file_size_bytes': fileSizeBytes,
      'mime_type': mimeType,
      'metadata': metadata?.toJson(),
      'rich_text_format': richTextFormat?.value,
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
        other.createdAt == createdAt &&
        other.contentType == contentType &&
        other.storagePath == storagePath &&
        other.fileSizeBytes == fileSizeBytes &&
        other.mimeType == mimeType &&
        other.metadata == metadata &&
        other.richTextFormat == richTextFormat;
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
      contentType,
      storagePath,
      fileSizeBytes,
      mimeType,
      metadata,
      richTextFormat,
    );
  }

  @override
  String toString() {
    return 'ClipboardItem(id: $id, userId: $userId, content: ${content.substring(0, content.length > 20 ? 20 : content.length)}..., deviceName: $deviceName, deviceType: $deviceType, targetDeviceTypes: $targetDeviceTypes, contentType: ${contentType.value}, isPublic: $isPublic, isEncrypted: $isEncrypted, createdAt: $createdAt)';
  }
}
