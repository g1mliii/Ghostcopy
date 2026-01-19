import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../clipboard_service.dart';
import '../clipboard_sync_service.dart';
import '../game_mode_service.dart';
import '../notification_service.dart';
import '../security_service.dart';
import '../settings_service.dart';

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
    IClipboardService? clipboardService,
    INotificationService? notificationService,
    IGameModeService? gameModeService,
  })  : _clipboardRepository = clipboardRepository,
        _settingsService = settingsService,
        _securityService = securityService,
        _clipboardService = clipboardService ?? ClipboardService.instance,
        _notificationService = notificationService,
        _gameModeService = gameModeService;

  final IClipboardRepository _clipboardRepository;
  final ISettingsService _settingsService;
  final ISecurityService _securityService;
  final IClipboardService _clipboardService;
  final INotificationService? _notificationService;
  final IGameModeService? _gameModeService;

  // Realtime subscription
  RealtimeChannel? _realtimeChannel;

  // Clipboard monitoring
  Timer? _clipboardMonitorTimer;
  String _lastMonitoredClipboard = '';
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
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('[ClipboardSyncService] Cannot subscribe: user not authenticated');
      return;
    }

    _realtimeChannel = Supabase.instance.client
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
            debugPrint('[ClipboardSyncService] Realtime update received: ${payload.eventType}');

            // Check if from another device
            final deviceName = payload.newRecord['device_name'] as String?;
            final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
            final isFromDifferentDevice = deviceName != null &&
                currentDeviceName != null &&
                deviceName != currentDeviceName;

            // Check if targeted to this device
            final targetDeviceTypeJson = payload.newRecord['target_device_type'];
            final currentDeviceType = ClipboardRepository.getCurrentDeviceType();

            // Parse target device types (can be null, a list, or a single string)
            List<String>? targetDeviceTypes;
            if (targetDeviceTypeJson != null) {
              if (targetDeviceTypeJson is List) {
                targetDeviceTypes = List<String>.from(targetDeviceTypeJson);
              } else if (targetDeviceTypeJson is String) {
                targetDeviceTypes = [targetDeviceTypeJson];
              }
            }

            final isTargetedToMe = targetDeviceTypes == null ||
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

    _autoReceiveDebounceTimer = Timer(
      const Duration(milliseconds: 500),
      () {
        if (_pendingAutoReceiveRecord != null) {
          _handleSmartAutoReceive(_pendingAutoReceiveRecord!);
          _pendingAutoReceiveRecord = null;
        }
      },
    );
  }

  /// Handle smart auto-receive logic with support for multiple content types
  Future<void> _handleSmartAutoReceive(Map<String, dynamic> record) async {
    try {
      final deviceType = record['device_type'] as String? ?? 'unknown';
      final now = DateTime.now();

      // Load auto-receive behavior from settings
      final autoReceiveBehavior = await _settingsService.getAutoReceiveBehavior();
      final staleDurationMinutes = await _settingsService.getClipboardStaleDurationMinutes();

      final shouldAutoCopy = switch (autoReceiveBehavior) {
        AutoReceiveBehavior.always => true,
        AutoReceiveBehavior.never => false,
        AutoReceiveBehavior.smart => () {
            final staleDuration = Duration(minutes: staleDurationMinutes);
            return _lastClipboardModificationTime == null ||
                now.difference(_lastClipboardModificationTime!) >= staleDuration;
          }(),
      };

      if (shouldAutoCopy) {
        // Auto-copy to clipboard
        final history = await _clipboardRepository.getHistory(limit: 1);

        if (history.isNotEmpty) {
          final item = history.first;

          try {
            await _copyItemToClipboard(item);
            debugPrint('[ClipboardSyncService] Auto-copied ${item.contentType.value} from $deviceType');

            _lastClipboardModificationTime = now;

            // Show notification or queue if Game Mode active
            if (_gameModeService?.isActive ?? false) {
              _gameModeService?.queueNotification(item);
              debugPrint('[ClipboardSyncService] Notification queued (Game Mode)');
            } else {
              _notificationService?.showToast(
                message: 'Auto-copied ${item.isImage ? 'image' : 'content'} from $deviceType',
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
        debugPrint('[ClipboardSyncService] Not auto-copying (${autoReceiveBehavior.name})');

        final history = await _clipboardRepository.getHistory(limit: 1);
        if (history.isEmpty) return;

        final item = history.first;
        final truncated = item.content.length > 40
            ? '${item.content.substring(0, 40)}...'
            : item.content;

        if (_gameModeService?.isActive ?? false) {
          _gameModeService?.queueNotification(item);
        } else {
          _notificationService?.showClickableToast(
            message: 'New clip from $deviceType: "$truncated"',
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
    _isMonitoring = false;
    debugPrint('[ClipboardSyncService] Clipboard monitoring stopped');
  }

  /// Check clipboard and auto-send if changed
  Future<void> _checkClipboardForAutoSend() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      final clipboardContent = clipboardData?.text ?? '';

      // Skip if empty or unchanged
      if (clipboardContent.isEmpty ||
          clipboardContent == _lastMonitoredClipboard) {
        return;
      }

      _lastMonitoredClipboard = clipboardContent;

      // Rate limiting
      if (_lastSendTime != null) {
        final timeSinceLastSend = DateTime.now().difference(_lastSendTime!);
        if (timeSinceLastSend < _minSendInterval) {
          debugPrint('[ClipboardSyncService] Auto-send rate limited');
          return;
        }
      }

      // Security check
      final detection = await _securityService.detectSensitiveDataAsync(
        clipboardContent,
      );
      if (detection.isSensitive) {
        debugPrint(
          '[ClipboardSyncService] Auto-send blocked: ${detection.type?.label} detected',
        );
        return;
      }

      // Auto-send
      debugPrint(
        '[ClipboardSyncService] Auto-sending: ${clipboardContent.substring(0, clipboardContent.length > 50 ? 50 : clipboardContent.length)}...',
      );
      await _autoSendClipboard(clipboardContent);
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Clipboard check failed: $e');
    }
  }

  /// Auto-send clipboard content
  Future<void> _autoSendClipboard(String content) async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // Content deduplication
      final contentHash = _calculateContentHash(content);
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
      final targetDevicesList = targetDevices.isEmpty ? null : targetDevices.toList();

      final item = ClipboardItem(
        id: '0',
        userId: userId,
        content: content,
        deviceName: currentDeviceName,
        deviceType: currentDeviceType,
        targetDeviceTypes: targetDevicesList,
        createdAt: DateTime.now(),
      );

      final result = await _clipboardRepository.insert(item);

      // Push notification now triggered by database webhook (send-clipboard-notification)
      // No client-side edge function invocation needed

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
    _lastMonitoredClipboard = content;

    // Update content hash to prevent duplicate sends
    _lastSentContentHash = _calculateContentHash(content);

    debugPrint('[ClipboardSyncService] Manual send notified, preventing duplicate auto-send');
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

    debugPrint('[ClipboardSync] 🔄 Starting polling mode (${interval.inMinutes} min)');

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

  @override
  void dispose() {
    debugPrint('[ClipboardSyncService] Disposing...');

    // Cancel timers
    _clipboardMonitorTimer?.cancel();
    _clipboardMonitorTimer = null;

    _autoReceiveDebounceTimer?.cancel();
    _autoReceiveDebounceTimer = null;

    _pollingTimer?.cancel(); // NEW - Cancel polling timer
    _pollingTimer = null;

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
