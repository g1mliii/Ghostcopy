import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../models/clipboard_item.dart';
import '../../models/exceptions.dart';
import '../../repositories/clipboard_repository.dart';
import '../clipboard_service.dart';
import '../clipboard_sync_service.dart';
import '../file_type_service.dart';
import '../game_mode_service.dart';
import '../notification_service.dart';
import '../obsidian_service.dart';
import '../security_service.dart';
import '../settings_service.dart';
import '../temp_file_service.dart';
import '../url_shortener_service.dart';
import '../webhook_service.dart';

/// Background service for clipboard synchronization
///
/// Runs continuously while app is in tray, handling:
/// - Realtime Supabase subscriptions
/// - Clipboard monitoring for auto-send
/// - Auto-receive logic with debouncing
/// - Push notification coordination
class ClipboardSyncService implements IClipboardSyncService {
  ClipboardSyncService({
    required IClipboardRepository clipboardRepository,
    required ISettingsService settingsService,
    required ISecurityService securityService,
    SupabaseClient? supabaseClient,
    IClipboardService? clipboardService,
    ITempFileService? tempFileService,
    INotificationService? notificationService,
    IGameModeService? gameModeService,
    IUrlShortenerService? urlShortenerService,
    IWebhookService? webhookService,
    IObsidianService? obsidianService,
  }) : _clipboardRepository = clipboardRepository,
       _settingsService = settingsService,
       _securityService = securityService,
       _supabaseClient = supabaseClient ?? Supabase.instance.client,
       _clipboardService = clipboardService ?? ClipboardService.instance,
       _tempFileService = tempFileService ?? TempFileService.instance,
       _notificationService = notificationService,
       _gameModeService = gameModeService,
       _urlShortenerService = urlShortenerService,
       _webhookService = webhookService,
       _obsidianService = obsidianService;

  final IClipboardRepository _clipboardRepository;
  final ISettingsService _settingsService;
  final ISecurityService _securityService;
  final SupabaseClient _supabaseClient;
  final IClipboardService _clipboardService;
  final ITempFileService _tempFileService;
  final INotificationService? _notificationService;
  final IGameModeService? _gameModeService;
  final IUrlShortenerService? _urlShortenerService;
  final IWebhookService? _webhookService;
  final IObsidianService? _obsidianService;

  // Realtime subscription
  RealtimeChannel? _realtimeChannel;

  // Clipboard monitoring
  Timer? _clipboardMonitorTimer;
  String _lastMonitoredClipboard = '';
  String?
  _lastClipboardFormat; // Track format for diagnostics and unsupported-format gating
  bool _isMonitoring = false;

  @override
  bool get isMonitoring => _isMonitoring;

  // Polling mode state
  Timer? _pollingTimer;
  String? _lastPolledItemId; // Track last seen item to avoid duplicates

  // Auto-receive debouncing
  Timer? _autoReceiveDebounceTimer;
  Map<String, dynamic>? _pendingAutoReceiveRecord;

  // Rate limiting for send operations
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // Temp file cleanup timer (cancellable - Fix #9)
  Timer? _tempFileCleanupTimer;

  // Pending background operations for clean shutdown (Fix #10)
  final Set<Future<void>> _pendingFutures = {};

  // Content deduplication
  String _lastSentContentHash = '';

  // Smart auto-receive: Track clipboard staleness
  DateTime? _lastClipboardModificationTime;

  // Callbacks for UI updates
  @override
  void Function()? onClipboardReceived;

  @override
  void Function(ClipboardItem item)? onClipboardSent;

  @override
  Future<void> initialize() async {
    debugPrint('[ClipboardSyncService] Initializing...');

    // Subscribe to realtime updates
    _subscribeToRealtimeUpdates();

    // Check if auto-send is enabled and start monitoring
    final autoSendEnabled = await _settingsService.getAutoSendEnabled();
    if (autoSendEnabled) {
      startClipboardMonitoring();
    }

    debugPrint('[ClipboardSyncService] Initialized');
  }

  /// Subscribe to real-time clipboard updates from Supabase
  void _subscribeToRealtimeUpdates() {
    final userId = _supabaseClient.auth.currentUser?.id;
    if (userId == null) {
      debugPrint(
        '[ClipboardSyncService] Cannot subscribe: user not authenticated',
      );
      return;
    }

    _realtimeChannel = _supabaseClient
        .channel('clipboard_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'clipboard',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            debugPrint(
              '[ClipboardSyncService] Realtime update received: ${payload.eventType}',
            );

            // Check if from another device
            final deviceName = payload.newRecord['device_name'] as String?;
            final currentDeviceName =
                ClipboardRepository.getCurrentDeviceName();
            final isFromDifferentDevice =
                deviceName != null &&
                currentDeviceName != null &&
                deviceName != currentDeviceName;

            // Check if targeted to this device
            final targetDeviceTypeJson =
                payload.newRecord['target_device_type'];
            final currentDeviceType =
                ClipboardRepository.getCurrentDeviceType();

            // Parse target device types (can be null, a list, or a single string)
            List<String>? targetDeviceTypes;
            if (targetDeviceTypeJson != null) {
              if (targetDeviceTypeJson is List) {
                targetDeviceTypes = List<String>.from(targetDeviceTypeJson);
              } else if (targetDeviceTypeJson is String) {
                targetDeviceTypes = [targetDeviceTypeJson];
              }
            }

            final isTargetedToMe =
                targetDeviceTypes == null ||
                targetDeviceTypes.contains(currentDeviceType);

            if (isFromDifferentDevice && isTargetedToMe) {
              _debouncedAutoReceive(payload.newRecord);
            }

            // Notify UI to refresh history
            onClipboardReceived?.call();
          },
        )
        .subscribe();

    debugPrint('[ClipboardSyncService] Realtime subscription active');
  }

  /// Debounce auto-receive to prevent clipboard thrashing
  void _debouncedAutoReceive(Map<String, dynamic> record) {
    _autoReceiveDebounceTimer?.cancel();
    _pendingAutoReceiveRecord = record;

    _autoReceiveDebounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (_pendingAutoReceiveRecord != null) {
        _handleSmartAutoReceive(_pendingAutoReceiveRecord!);
        _pendingAutoReceiveRecord = null;
      }
    });
  }

  /// Handle smart auto-receive logic with support for multiple content types
  Future<void> _handleSmartAutoReceive(Map<String, dynamic> record) async {
    try {
      final deviceType = record['device_type'] as String? ?? 'unknown';
      final now = DateTime.now();

      // Load auto-receive behavior from settings
      final autoReceiveBehavior = await _settingsService
          .getAutoReceiveBehavior();
      final staleDurationMinutes = await _settingsService
          .getClipboardStaleDurationMinutes();

      final shouldAutoCopy = switch (autoReceiveBehavior) {
        AutoReceiveBehavior.always => true,
        AutoReceiveBehavior.never => false,
        AutoReceiveBehavior.smart => () {
          final staleDuration = Duration(minutes: staleDurationMinutes);
          final isStale =
              _lastClipboardModificationTime == null ||
              now.difference(_lastClipboardModificationTime!) >= staleDuration;

          debugPrint('[ClipboardSyncService] Smart Auto-Receive Check:');
          debugPrint('  - Last Mod: $_lastClipboardModificationTime');
          debugPrint('  - Stale Threshold: $staleDurationMinutes min');
          debugPrint(
            '  - Is Stale: $isStale (Diff: ${now.difference(_lastClipboardModificationTime ?? DateTime.fromMillisecondsSinceEpoch(0))})',
          );

          return isStale;
        }(),
      };

      debugPrint(
        '[ClipboardSyncService] Auto-Receive Behavior: ${autoReceiveBehavior.name}',
      );
      debugPrint('[ClipboardSyncService] Should Auto-Copy: $shouldAutoCopy');

      if (shouldAutoCopy) {
        // Auto-copy to clipboard
        final history = await _clipboardRepository.getHistory(limit: 1);

        if (history.isNotEmpty) {
          final item = history.first;

          try {
            await _copyItemToClipboard(item);
            debugPrint(
              '[ClipboardSyncService] Auto-copied ${item.contentType.value} from $deviceType',
            );

            // Prevent re-sending auto-received content (stops ping-pong between devices)
            // Update both dedup hashes so clipboard monitor won't treat this as new content
            if (!item.isFile && !item.isImage) {
              _lastMonitoredClipboard = md5
                  .convert(utf8.encode(item.content))
                  .toString();
              _lastSentContentHash = _calculateContentHash(item.content);
            }

            _lastClipboardModificationTime = now;

            // Show notification or queue if Game Mode active
            if (_gameModeService?.isActive ?? false) {
              _gameModeService?.queueNotification(item);
              debugPrint(
                '[ClipboardSyncService] Notification queued (Game Mode)',
              );
            } else {
              final contentTypeStr = item.isFile
                  ? 'file'
                  : item.isImage
                  ? 'image'
                  : 'content';
              _notificationService?.showToast(
                message: 'Auto-copied $contentTypeStr from $deviceType',
                type: NotificationType.success,
              );
            }
          } on Exception catch (e) {
            debugPrint('[ClipboardSyncService] Failed to auto-copy: $e');
            _notificationService?.showToast(
              message: 'Failed to auto-copy from $deviceType',
              type: NotificationType.error,
            );
          }
        }
      } else {
        // Not auto-copying - show notification with action
        debugPrint(
          '[ClipboardSyncService] Not auto-copying (${autoReceiveBehavior.name})',
        );

        final history = await _clipboardRepository.getHistory(limit: 1);
        if (history.isEmpty) return;

        final item = history.first;

        // Format message based on content type
        String message;
        if (item.isFile) {
          final filename = item.metadata?.originalFilename ?? 'file';
          message = 'New file from $deviceType: "$filename"';
        } else if (item.isImage) {
          final size = item.displaySize;
          message = 'New image from $deviceType ($size)';
        } else {
          final truncated = item.content.length > 40
              ? '${item.content.substring(0, 40)}...'
              : item.content;
          message = 'New clip from $deviceType: "$truncated"';
        }

        if (_gameModeService?.isActive ?? false) {
          _gameModeService?.queueNotification(item);
        } else {
          _notificationService?.showClickableToast(
            message: message,
            actionLabel: 'Copy',
            duration: const Duration(seconds: 5),
            onAction: () async {
              try {
                await _copyItemToClipboard(item);
                debugPrint('[ClipboardSyncService] Copied from notification');
              } on Exception catch (e) {
                debugPrint('[ClipboardSyncService] Failed to copy: $e');
                // Show error toast (analyzer knows notificationService can't be null here)
                // ignore: invalid_null_aware_operator
                _notificationService?.showToast(
                  message: 'Failed to copy',
                  type: NotificationType.error,
                );
              }
            },
          );
        }
      }
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-receive failed: $e');
    }
  }

  /// Copy a clipboard item to the system clipboard, supporting multiple content types
  ///
  /// Uses super_clipboard for full format support:
  /// - Plain text (copied as plain text)
  /// - Rich text (HTML/Markdown - HTML copied with plain text fallback)
  /// - Images (PNG/JPEG/GIF - downloaded from storage and copied as image)
  /// - Files (PDF, DOC, ZIP, etc. - downloaded to temp, path copied to clipboard)
  /// - Encrypted content (already decrypted by repository)
  Future<void> _copyItemToClipboard(ClipboardItem item) async {
    switch (item.contentType) {
      case ContentType.text:
        // Plain text - copy directly
        await _clipboardService.writeText(item.content);

      case ContentType.html:
        // HTML - copy with plain text fallback (super_clipboard handles both)
        await _clipboardService.writeHtml(item.content);
        debugPrint('[ClipboardSyncService] Copied HTML to clipboard');

      case ContentType.markdown:
        // Markdown - copy as plain text (markdown isn't standard clipboard format)
        await _clipboardService.writeText(item.content);
        debugPrint('[ClipboardSyncService] Copied Markdown as plain text');

      case ContentType.imagePng:
      case ContentType.imageJpeg:
      case ContentType.imageGif:
        // Image - download from storage and copy to clipboard
        if (item.storagePath == null) {
          throw RepositoryException(
            'Image item ${item.id} missing storage_path',
          );
        }

        final imageBytes = await _clipboardRepository.downloadFile(item);
        if (imageBytes == null || imageBytes.isEmpty) {
          throw RepositoryException(
            'Failed to download image from storage path: ${item.storagePath}',
          );
        }

        // Copy image to clipboard using super_clipboard (full native support)
        await _clipboardService.writeImage(imageBytes);
        debugPrint(
          '[ClipboardSyncService] Copied image (${item.displaySize}) to clipboard',
        );

      default:
        // Files - download from storage, save to temp, copy path to clipboard
        if (item.isFile) {
          if (item.storagePath == null) {
            throw RepositoryException(
              'File item ${item.id} missing storage_path',
            );
          }

          final fileBytes = await _clipboardRepository.downloadFile(item);
          if (fileBytes == null || fileBytes.isEmpty) {
            throw RepositoryException(
              'Failed to download file from storage path: ${item.storagePath}',
            );
          }

          // Get original filename from metadata, fallback to generic name
          final filename = item.metadata?.originalFilename ?? 'file.bin';

          // Save to temp directory
          final tempFile = await _tempFileService.saveTempFile(
            fileBytes,
            filename,
          );

          // Copy file path to clipboard
          await _clipboardService.writeFilePath(tempFile.path);
          debugPrint(
            '[ClipboardSyncService] Copied file ($filename, ${item.displaySize}) to clipboard',
          );

          // Schedule temp file cleanup after clipboard operation completes
          // Use cancellable timer instead of fire-and-forget Future.delayed (Fix #9)
          _tempFileCleanupTimer?.cancel();
          _tempFileCleanupTimer = Timer(const Duration(seconds: 5), () {
            if (!_isDisposed) {
              _tempFileService.deleteTempFile(tempFile.path);
            }
          });
        }
    }
  }

  @override
  void startClipboardMonitoring() {
    if (_isMonitoring) {
      debugPrint('[ClipboardSyncService] Already monitoring clipboard');
      return;
    }

    _clipboardMonitorTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkClipboardForAutoSend(),
    );
    _isMonitoring = true;
    debugPrint('[ClipboardSyncService] Clipboard monitoring started');
  }

  @override
  void stopClipboardMonitoring() {
    _clipboardMonitorTimer?.cancel();
    _clipboardMonitorTimer = null;
    _lastMonitoredClipboard = '';
    _lastClipboardFormat = null;
    _isMonitoring = false;
    debugPrint('[ClipboardSyncService] Clipboard monitoring stopped');
  }

  /// Check clipboard and auto-send if changed
  Future<void> _checkClipboardForAutoSend() async {
    try {
      // OPTIMIZATION: Quick format check to avoid expensive full reads
      final reader = await SystemClipboard.instance?.read();
      if (reader == null) return;

      // Determine current clipboard format (cheapest operation)
      String? currentFormat;
      if (reader.canProvide(Formats.fileUri)) {
        currentFormat = 'file';
      } else if (reader.canProvide(Formats.png)) {
        currentFormat = 'image/png';
      } else if (reader.canProvide(Formats.jpeg)) {
        currentFormat = 'image/jpeg';
      } else if (reader.canProvide(Formats.plainText)) {
        currentFormat = 'text';
      } else if (reader.canProvide(Formats.htmlText)) {
        currentFormat = 'html';
      }

      // Only skip on repeated unsupported/unknown formats.
      // For known formats (text/image/file/html), we must still read and hash
      // to detect content changes within the same format category.
      if (currentFormat == null && _lastClipboardFormat == null) {
        return;
      }

      _lastClipboardFormat = currentFormat;

      // Read clipboard using ClipboardService (supports all formats)
      final clipboardContent = await _clipboardService.read();

      // Skip if empty
      if (clipboardContent.isEmpty) {
        return;
      }

      // Calculate hash for deduplication (works for text and images)
      final contentHash = _calculateClipboardContentHash(clipboardContent);

      // Skip if unchanged (compare hashes instead of raw content)
      if (contentHash == _lastMonitoredClipboard) {
        return;
      }

      _lastMonitoredClipboard = contentHash;

      // Rate limiting
      if (_lastSendTime != null) {
        final timeSinceLastSend = DateTime.now().difference(_lastSendTime!);
        if (timeSinceLastSend < _minSendInterval) {
          debugPrint('[ClipboardSyncService] Auto-send rate limited');
          return;
        }
      }

      // Security check (only for text content)
      if (clipboardContent.hasText) {
        final detection = await _securityService.detectSensitiveDataAsync(
          clipboardContent.text!,
        );
        if (detection.isSensitive) {
          debugPrint(
            '[ClipboardSyncService] Auto-send blocked: ${detection.type?.label} detected',
          );
          return;
        }
      }

      // Auto-send based on content type
      if (clipboardContent.hasFile) {
        debugPrint(
          '[ClipboardSyncService] Auto-sending file: ${clipboardContent.filename} (${clipboardContent.fileBytes!.length} bytes)',
        );
        await _autoSendFile(
          clipboardContent.fileBytes!,
          clipboardContent.filename!,
          clipboardContent.mimeType,
        );
      } else if (clipboardContent.hasImage) {
        debugPrint(
          '[ClipboardSyncService] Auto-sending image: ${clipboardContent.imageBytes!.length} bytes (${clipboardContent.mimeType})',
        );
        await _autoSendImage(
          clipboardContent.imageBytes!,
          clipboardContent.mimeType!,
        );
      } else if (clipboardContent.hasText) {
        final textContent = clipboardContent.text!;
        debugPrint(
          '[ClipboardSyncService] Auto-sending text (${textContent.length} chars)',
        );
        await _autoSendClipboard(textContent);
      }
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Clipboard check failed: $e');
    }
  }

  /// Calculate hash for clipboard content (text or image)
  /// Uses partial hash for large content (>1MB) to reduce CPU usage (Fix #13)
  String _calculateClipboardContentHash(ClipboardContent content) {
    if (content.hasImage) {
      final bytes = content.imageBytes!;
      // Use partial hash for large images (>1MB)
      if (bytes.length > 1024 * 1024) {
        return _partialHash(bytes);
      }
      return md5.convert(bytes).toString();
    } else if (content.hasText) {
      final text = content.text!;
      // Use partial hash for large text (>1MB)
      if (text.length > 1024 * 1024) {
        final bytes = utf8.encode(text);
        return _partialHash(bytes);
      }
      return md5.convert(utf8.encode(text)).toString();
    }
    return '';
  }

  /// Calculate partial hash for large content (first 4KB + last 4KB + size)
  /// This is much faster than hashing multi-MB content (Fix #13)
  String _partialHash(Uint8List bytes) {
    const chunkSize = 4096;
    final firstChunk = bytes.sublist(0, chunkSize.clamp(0, bytes.length));
    final lastChunk = bytes.length > chunkSize
        ? bytes.sublist(bytes.length - chunkSize)
        : firstChunk;
    final sizeBytes = utf8.encode(bytes.length.toString());
    final builder = BytesBuilder(copy: false)
      ..add(firstChunk)
      ..add(lastChunk)
      ..add(sizeBytes);
    return md5.convert(builder.takeBytes()).toString();
  }

  /// Auto-send clipboard content
  Future<void> _autoSendClipboard(String content) async {
    try {
      final userId = _supabaseClient.auth.currentUser?.id;
      if (userId == null) return;

      // URL shortening (if enabled)
      var processedContent = content;
      final urlShortener = _urlShortenerService;
      if (urlShortener != null) {
        final autoShortenEnabled = await _settingsService.getAutoShortenUrls();
        if (autoShortenEnabled && urlShortener.isUrl(content)) {
          processedContent = await urlShortener.shortenUrl(content);
        }
      }

      // Content deduplication
      final contentHash = _calculateContentHash(processedContent);
      if (contentHash == _lastSentContentHash) {
        debugPrint('[ClipboardSyncService] Skipping duplicate content');
        return;
      }
      _lastSentContentHash = contentHash;

      // Get target devices
      final targetDevices = await _settingsService.getAutoSendTargetDevices();

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();

      // Convert Set to List (null if empty = all devices)
      final targetDevicesList = targetDevices.isEmpty
          ? null
          : targetDevices.toList();

      final item = ClipboardItem(
        id: '0',
        userId: userId,
        content: processedContent,
        deviceName: currentDeviceName,
        deviceType: currentDeviceType,
        targetDeviceTypes: targetDevicesList,
        createdAt: DateTime.now(),
      );

      final result = await _clipboardRepository.insert(item);

      // Push notification now triggered by database webhook (send-clipboard-notification)
      // No client-side edge function invocation needed

      // Fire webhook (if enabled) - non-blocking
      _fireWebhook(processedContent, currentDeviceType);

      // Append to Obsidian (if enabled) - non-blocking
      _appendToObsidian(processedContent);

      _lastSendTime = DateTime.now();

      // Notify UI
      onClipboardSent?.call(result);

      // Show success toast
      final targetText = targetDevices.isEmpty
          ? 'all devices'
          : targetDevices.length == 1
          ? targetDevices.first
          : '${targetDevices.length} device types';
      _notificationService?.showToast(
        message: 'Auto-sent to $targetText',
        type: NotificationType.success,
      );

      debugPrint(
        '[ClipboardSyncService] Auto-sent to ${targetDevices.isEmpty ? "all devices" : targetDevices.join(", ")}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send failed: $e');

      // Show error toast
      _notificationService?.showToast(
        message: 'Auto-send failed',
        type: NotificationType.error,
      );
    }
  }

  /// Auto-send image content
  Future<void> _autoSendImage(Uint8List imageBytes, String mimeType) async {
    try {
      final userId = _supabaseClient.auth.currentUser?.id;
      if (userId == null) return;

      // Content deduplication (hash image bytes)
      final contentHash = md5.convert(imageBytes).toString();
      if (contentHash == _lastSentContentHash) {
        debugPrint('[ClipboardSyncService] Skipping duplicate image');
        return;
      }
      _lastSentContentHash = contentHash;

      // Map mimeType to ContentType
      ContentType contentType;
      switch (mimeType) {
        case 'image/png':
          contentType = ContentType.imagePng;
        case 'image/jpeg':
        case 'image/jpg':
          contentType = ContentType.imageJpeg;
        case 'image/gif':
          contentType = ContentType.imageGif;
        default:
          debugPrint(
            '[ClipboardSyncService] Unsupported image type: $mimeType',
          );
          return;
      }

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();

      // Get target devices
      final targetDevices = await _settingsService.getAutoSendTargetDevices();

      // Convert Set to List (null if empty = all devices)
      final targetDevicesList = targetDevices.isEmpty
          ? null
          : targetDevices.toList();

      // Insert image using repository
      final result = await _clipboardRepository.insertImage(
        userId: userId,
        deviceType: currentDeviceType,
        deviceName: currentDeviceName,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: targetDevicesList,
      );

      _lastSendTime = DateTime.now();

      // Notify UI
      onClipboardSent?.call(result);

      // Show success toast
      final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);
      final targetText = targetDevices.isEmpty
          ? 'all devices'
          : targetDevices.length == 1
          ? targetDevices.first
          : '${targetDevices.length} device types';
      _notificationService?.showToast(
        message: 'Auto-sent image ($sizeKB KB) to $targetText',
        type: NotificationType.success,
      );

      debugPrint(
        '[ClipboardSyncService] Auto-sent image to ${targetDevices.isEmpty ? "all devices" : targetDevices.join(", ")}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send image failed: $e');

      // Show error toast
      _notificationService?.showToast(
        message: 'Auto-send image failed',
        type: NotificationType.error,
      );
    }
  }

  /// Auto-send file content
  Future<void> _autoSendFile(
    Uint8List fileBytes,
    String filename,
    String? mimeType,
  ) async {
    try {
      final userId = _supabaseClient.auth.currentUser?.id;
      if (userId == null) return;

      // Content deduplication (hash file bytes)
      final contentHash = md5.convert(fileBytes).toString();
      if (contentHash == _lastSentContentHash) {
        debugPrint('[ClipboardSyncService] Skipping duplicate file');
        return;
      }
      _lastSentContentHash = contentHash;

      // Use FileTypeService to detect file type
      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        fileBytes,
        filename,
      );

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();

      // Get target devices
      final targetDevices = await _settingsService.getAutoSendTargetDevices();

      // Convert Set to List (null if empty = all devices)
      final targetDevicesList = targetDevices.isEmpty
          ? null
          : targetDevices.toList();

      // Insert file using repository
      final result = await _clipboardRepository.insertFile(
        userId: userId,
        deviceType: currentDeviceType,
        deviceName: currentDeviceName,
        fileBytes: fileBytes,
        mimeType: mimeType ?? fileTypeInfo.mimeType,
        contentType: fileTypeInfo.contentType,
        originalFilename: filename,
        targetDeviceTypes: targetDevicesList,
      );

      _lastSendTime = DateTime.now();

      // Notify UI
      onClipboardSent?.call(result);

      // Show success toast
      final sizeKB = (fileBytes.length / 1024).toStringAsFixed(1);
      final targetText = targetDevices.isEmpty
          ? 'all devices'
          : targetDevices.length == 1
          ? targetDevices.first
          : '${targetDevices.length} device types';
      _notificationService?.showToast(
        message: 'Auto-sent file "$filename" ($sizeKB KB) to $targetText',
        type: NotificationType.success,
      );

      debugPrint(
        '[ClipboardSyncService] Auto-sent file to ${targetDevices.isEmpty ? "all devices" : targetDevices.join(", ")}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send file failed: $e');

      // Show error toast
      _notificationService?.showToast(
        message: 'Auto-send file failed',
        type: NotificationType.error,
      );
    }
  }

  /// Calculate SHA-256 hash for content deduplication
  String _calculateContentHash(String content) {
    final bytes = utf8.encode(content);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Update clipboard modification time (called from UI when user manually copies)
  @override
  void updateClipboardModificationTime() {
    _lastClipboardModificationTime = DateTime.now();
  }

  /// Notify service that content was manually sent via UI
  @override
  void notifyManualSend(String content) {
    // Update last monitored clipboard to prevent duplicate auto-send
    _lastMonitoredClipboard = _calculateContentHash(content);

    // Update content hash to prevent duplicate sends
    _lastSentContentHash = _calculateContentHash(content);

    debugPrint(
      '[ClipboardSyncService] Manual send notified, preventing duplicate auto-send',
    );
  }

  // ========== CONNECTION MODE MANAGEMENT ==========

  /// Pause realtime subscription (keep it for resume)
  @override
  void pauseRealtime() {
    if (_realtimeChannel == null) return;

    debugPrint('[ClipboardSync] ⏸️  Pausing realtime subscription');
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;
  }

  /// Resume realtime subscription
  @override
  void resumeRealtime() {
    if (_realtimeChannel != null) return; // Already active

    debugPrint('[ClipboardSync] ▶️  Resuming realtime subscription');
    _subscribeToRealtimeUpdates();
  }

  /// Start polling mode
  @override
  void startPolling({Duration interval = const Duration(minutes: 5)}) {
    if (_pollingTimer != null) return; // Already polling

    debugPrint(
      '[ClipboardSync] 🔄 Starting polling mode (${interval.inMinutes} min)',
    );

    _pollingTimer = Timer.periodic(interval, (_) async {
      await _pollForNewClipboards();
    });
  }

  /// Stop polling mode
  @override
  void stopPolling() {
    if (_pollingTimer == null) return;

    debugPrint('[ClipboardSync] 🛑 Stopping polling mode');
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// Reinitialize realtime subscription with new user ID
  /// Call this when user logs in or switches accounts
  @override
  void reinitializeForUser() {
    debugPrint('[ClipboardSyncService] 🔄 Reinitializing for new user');

    // Unsubscribe from old realtime channel
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;

    // Subscribe with new user ID (no need to disconnect - auth token updates automatically)
    _subscribeToRealtimeUpdates();
  }

  /// Poll for new clipboard items
  Future<void> _pollForNewClipboards() async {
    try {
      debugPrint('[ClipboardSync] 🔍 Polling for new items...');

      // Get latest items
      final history = await _clipboardRepository.getHistory(limit: 5);

      if (history.isEmpty) return;

      // Check if there are new items since last poll
      final latestItem = history.first;
      if (_lastPolledItemId != null && latestItem.id == _lastPolledItemId) {
        debugPrint('[ClipboardSync] ✅ No new items');
        return; // No new items
      }

      _lastPolledItemId = latestItem.id;

      // Check if from different device
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
      final isFromDifferentDevice = latestItem.deviceName != currentDeviceName;

      if (isFromDifferentDevice) {
        debugPrint('[ClipboardSync] 📥 New item from ${latestItem.deviceType}');
        await _handleSmartAutoReceive({
          'content': latestItem.content,
          'device_type': latestItem.deviceType,
        });
      }

      // Notify UI to refresh
      onClipboardReceived?.call();
    } on Exception catch (e) {
      debugPrint('[ClipboardSync] ❌ Polling error: $e');
    }
  }

  bool _isDisposed = false;

  /// Fire webhook (non-blocking with tracking for clean disposal - Fix #10)
  void _fireWebhook(String content, String deviceType) {
    if (_isDisposed) return;
    final webhook = _webhookService;
    if (webhook == null) return;

    // Track the future for clean disposal
    final future = () async {
      if (_isDisposed) return;
      try {
        final webhookEnabled = await _settingsService.getWebhookEnabled();
        if (!webhookEnabled || _isDisposed) return;

        final webhookUrl = await _settingsService.getWebhookUrl();
        if (webhookUrl == null || webhookUrl.isEmpty) {
          debugPrint(
            '[ClipboardSyncService] ⚠️  Webhook enabled but no URL configured',
          );
          return;
        }

        final payload = {
          'content': content,
          'deviceType': deviceType,
          'timestamp': DateTime.now().toIso8601String(),
        };

        if (!_isDisposed) {
          await webhook.sendWebhook(webhookUrl, payload);
        }
      } on Exception catch (e) {
        debugPrint('[ClipboardSyncService] ❌ Webhook error: $e');
      }
    }();

    _pendingFutures.add(future);
    future.whenComplete(() => _pendingFutures.remove(future));
  }

  /// Append to Obsidian vault (non-blocking with tracking - Fix #10)
  void _appendToObsidian(String content) {
    if (_isDisposed) return;
    final obsidian = _obsidianService;
    if (obsidian == null) return;

    // Track the future for clean disposal
    final future = () async {
      if (_isDisposed) return;
      try {
        final obsidianEnabled = await _settingsService.getObsidianEnabled();
        if (!obsidianEnabled || _isDisposed) return;

        final vaultPath = await _settingsService.getObsidianVaultPath();
        if (vaultPath == null || vaultPath.isEmpty) {
          debugPrint(
            '[ClipboardSyncService] ⚠️  Obsidian enabled but no vault path configured',
          );
          return;
        }

        final fileName = await _settingsService.getObsidianFileName();

        if (!_isDisposed) {
          await obsidian.appendToVault(
            vaultPath: vaultPath,
            fileName: fileName,
            content: content,
          );
        }
      } on Exception catch (e) {
        debugPrint('[ClipboardSyncService] ❌ Obsidian error: $e');
      }
    }();

    _pendingFutures.add(future);
    future.whenComplete(() => _pendingFutures.remove(future));
  }

  @override
  void dispose() {
    debugPrint('[ClipboardSyncService] Disposing...');
    _isDisposed = true;

    // Cancel timers
    _clipboardMonitorTimer?.cancel();
    _clipboardMonitorTimer = null;

    _autoReceiveDebounceTimer?.cancel();
    _autoReceiveDebounceTimer = null;

    _pollingTimer?.cancel();
    _pollingTimer = null;

    // Cancel temp file cleanup timer (Fix #9)
    _tempFileCleanupTimer?.cancel();
    _tempFileCleanupTimer = null;

    // Note: _pendingFutures are tracked but not awaited in dispose()
    // since dispose() is sync. The _isDisposed flag prevents new work.
    // In a real async dispose, we would: await Future.wait(_pendingFutures);

    // Unsubscribe from realtime
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;

    // Clear callbacks to prevent memory leaks
    onClipboardReceived = null;
    onClipboardSent = null;

    _isMonitoring = false;

    debugPrint('[ClipboardSyncService] Disposed');
  }
}
