import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    required this._clipboardRepository,
    required this._settingsService,
    required this._securityService,
    SupabaseClient? supabaseClient,
    IClipboardService? clipboardService,
    ITempFileService? tempFileService,
    this._notificationService,
    this._gameModeService,
    this._urlShortenerService,
    this._webhookService,
    this._obsidianService,
  }) : _supabaseClient = supabaseClient ?? Supabase.instance.client,
       _clipboardService = clipboardService ?? ClipboardService.instance,
       _tempFileService = tempFileService ?? TempFileService.instance;

  final IClipboardRepository _clipboardRepository;
  final ISettingsService _settingsService;
  final ISecurityService _securityService;
  final SupabaseClient _supabaseClient;
  final IClipboardService _clipboardService;
  final ITempFileService _tempFileService;
  INotificationService? _notificationService;

  /// Attach the notifier after construction.
  ///
  /// main.dart cannot pass it to the constructor: NotificationService needs
  /// WindowService, which needs LifecycleController, which needs this service.
  /// It used to be left null for that reason, with a note that notifications
  /// would "just skip" - which meant every received clip was copied silently
  /// and no desktop ever showed a notification for one. Only Game Mode's queue,
  /// flushed through main.dart, got through.
  void attachNotificationService(INotificationService service) {
    if (_isDisposed) return;
    _notificationService = service;
    // Anything raised in the gap between subscribing and this call - a clip
    // that arrived during startup - is shown now rather than dropped.
    final pending = List.of(_pendingNotices);
    _pendingNotices.clear();
    for (final show in pending) {
      show(service);
    }
  }

  /// Notices raised before [attachNotificationService], bounded so a burst
  /// during startup cannot grow without limit.
  final List<void Function(INotificationService)> _pendingNotices = [];

  void _notify(void Function(INotificationService) show) {
    final service = _notificationService;
    if (service != null) {
      show(service);
    } else if (_pendingNotices.length < 10) {
      _pendingNotices.add(show);
    }
  }

  final IGameModeService? _gameModeService;
  final IUrlShortenerService? _urlShortenerService;
  final IWebhookService? _webhookService;
  final IObsidianService? _obsidianService;

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

  int _clipboardWritesInProgress = 0;

  // Pending background operations for clean shutdown (Fix #10)
  final Set<Future<void>> _pendingFutures = {};

  // Content deduplication
  String _lastSentContentHash = '';

  /// When the user last changed the clipboard themselves, as far as this
  /// service can tell. Smart auto-receive copies a received clip only once
  /// this is older than the stale duration, so it never overwrites something
  /// the user just copied. Null until a change has been seen, which counts as
  /// stale.
  DateTime? _lastClipboardModificationTime;

  /// Polls the pasteboard change counter; see [startClipboardActivityWatch].
  Timer? _activityTimer;

  /// The counter value last seen, including the one GhostCopy's own writes
  /// leave behind - so only somebody else's change moves it.
  int? _activityChangeCount;

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

    await refreshClipboardActivityWatch();

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

            // Check if from another device.
            //
            // A plain inequality, deliberately: the null guards that used to be
            // here made this false whenever either side had no name, and mobile
            // sends device_name: null on every path. That meant a clip sent
            // from the phone never triggered auto-receive on the desktop -
            // the Mobile -> Desktop half of sync - and it only appeared to work
            // because the polling fallback (_pollForNewClipboards) compares the
            // same two values WITHOUT the guards and takes over after 15
            // minutes idle. Matching that comparison here keeps the two paths
            // in agreement.
            //
            // Known limit: this identifies devices by name, so two machines
            // sharing a hostname will not receive from each other. Fixing that
            // needs a device id on the clipboard row.
            final deviceName = payload.newRecord['device_name'] as String?;
            final currentDeviceName =
                ClipboardRepository.getCurrentDeviceName();
            final isFromDifferentDevice = deviceName != currentDeviceName;

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
      final id = record['id']?.toString();
      final userId = _supabaseClient.auth.currentUser?.id;
      if (id == null || userId == null || _isDisposed) return;
      final item = await _clipboardRepository.getById(id);
      if (item == null ||
          _isDisposed ||
          _supabaseClient.auth.currentUser?.id != userId ||
          !_canReceive(item)) {
        return;
      }
      // Delivery to integrations is independent of the clipboard copy policy.
      if (item.contentType == ContentType.text ||
          item.contentType == ContentType.html ||
          item.contentType == ContentType.markdown) {
        _fireIntegrations(
          content: item.content,
          deviceType: item.deviceType,
          direction: 'received',
        );
      }
      final deviceType = item.deviceType;
      // clock rather than DateTime so tests can move time past the window.
      final now = clock.now();

      // Load auto-receive behavior from settings
      final autoReceiveBehavior = await _settingsService
          .getAutoReceiveBehavior();
      final staleDurationMinutes = await _settingsService
          .getClipboardStaleDurationMinutes();
      if (_isDisposed || !_canReceive(item)) return;

      // The watch samples every 30 seconds, so a copy made since the last
      // sample would otherwise be invisible here and get overwritten - the
      // very thing smart receive exists to prevent. Read the counter now; a
      // change since the last sample counts as a copy made this moment.
      if (autoReceiveBehavior == AutoReceiveBehavior.smart) {
        await _checkClipboardActivity();
        if (_isDisposed || !_canReceive(item)) return;
      }

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
        try {
          await _copyItemToClipboard(item);
          debugPrint(
            '[ClipboardSyncService] Auto-copied ${item.contentType.value} from $deviceType',
          );

          // Deliberately not stamping _lastClipboardModificationTime: this
          // is GhostCopy's write, not the user's. Counting it made a second
          // clip sent within the stale window stay uncopied, because the
          // first one's arrival looked like the user had just copied.

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
            _notify(
              (n) => n.showToast(
                message: 'Auto-copied $contentTypeStr from $deviceType',
                type: NotificationType.success,
              ),
            );
          }
        } on Exception catch (e) {
          debugPrint('[ClipboardSyncService] Failed to auto-copy: $e');
          _notify(
            (n) => n.showToast(
              message: 'Failed to auto-copy from $deviceType',
              type: NotificationType.error,
            ),
          );
        }
      } else {
        // Not auto-copying - show notification with action
        debugPrint(
          '[ClipboardSyncService] Not auto-copying (${autoReceiveBehavior.name})',
        );

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
          _notify(
            (n) => n.showClickableToast(
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
            ),
          );
        }
      }
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-receive failed: $e');
    }
  }

  bool _canReceive(ClipboardItem item) {
    final targets = item.targetDeviceTypes;
    return item.userId == _supabaseClient.auth.currentUser?.id &&
        item.deviceName != ClipboardRepository.getCurrentDeviceName() &&
        (targets == null ||
            targets.contains(ClipboardRepository.getCurrentDeviceType()));
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
    if (_isDisposed || !_canReceive(item)) return;
    _clipboardWritesInProgress++;
    var writtenContent = const ClipboardContent.empty();
    try {
      switch (item.contentType) {
        case ContentType.text:
          // Plain text - copy directly
          await _clipboardService.writeText(item.content);
          writtenContent = ClipboardContent.text(item.content);

        case ContentType.html:
          // HTML - copy with plain text fallback (super_clipboard handles both)
          await _clipboardService.writeHtml(item.content);
          writtenContent = ClipboardContent.html(item.content);
          debugPrint('[ClipboardSyncService] Copied HTML to clipboard');

        case ContentType.markdown:
          // Markdown - copy as plain text (markdown isn't standard clipboard format)
          await _clipboardService.writeText(item.content);
          writtenContent = ClipboardContent.text(item.content);
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
          writtenContent = ClipboardContent.image(
            imageBytes,
            item.mimeType ?? 'image/png',
          );
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
            writtenContent = ClipboardContent.file(
              fileBytes,
              filename,
              item.mimeType,
            );
            debugPrint(
              '[ClipboardSyncService] Copied file ($filename, ${item.displaySize}) to clipboard',
            );

            // The clipboard holds a URI. Periodic cleanup preserves its backing
            // file for as long as the URI is still on the clipboard.
          }
      }
      // Native platforms may normalize an image or an HTML clipboard write.
      // Record that representation when available so the next monitor tick
      // compares exactly the bytes it will read, for every content type.
      try {
        final actual = await _clipboardService.read();
        if (!actual.isEmpty) writtenContent = actual;
      } on Exception catch (e) {
        debugPrint('[ClipboardSyncService] Could not read back clipboard: $e');
      }
      _recordClipboardContent(
        writtenContent.text ?? '',
        clipboardContent: writtenContent,
      );
    } finally {
      // Absorb the counter bump this write caused, so the activity watch does
      // not mistake GhostCopy's write for the user copying something.
      _activityChangeCount =
          await _readClipboardChangeCount() ?? _activityChangeCount;
      _clipboardWritesInProgress--;
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
    // The hash is deliberately kept. Monitoring stops and restarts around
    // screen lock and system sleep, and clearing it made the first tick after
    // every resume treat the unchanged clipboard as new and send it again.
    _isMonitoring = false;
    debugPrint('[ClipboardSyncService] Clipboard monitoring stopped');
  }

  /// Check clipboard and auto-send if changed
  /// The clipboard's change counter, or null where it is unavailable.
  ///
  /// NSPasteboard's changeCount on macOS, GetClipboardSequenceNumber on
  /// Windows - both answered natively on this channel. Reading the clipboard
  /// pulls the whole payload - a copied file or image is re-read from disk in
  /// full - so this cheap integer gates that read. Linux has no counter and
  /// reads as before.
  static const _clipboardChangeChannel = MethodChannel(
    'com.ghostcopy.app/clipboard_change',
  );
  int? _lastClipboardChangeCount;

  /// The counter value whose read came back empty, so that exact pasteboard
  /// state is not read again while it is still there.
  int? _lastEmptyChangeCount;

  Future<int?> _readClipboardChangeCount() async {
    if (!Platform.isMacOS && !Platform.isWindows) return null;
    try {
      return await _clipboardChangeChannel.invokeMethod<int>('changeCount');
    } on PlatformException catch (e) {
      debugPrint('[ClipboardSyncService] changeCount unavailable: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _checkClipboardForAutoSend() async {
    if (_clipboardWritesInProgress > 0 || _isDisposed) return;
    try {
      // Nothing written to the pasteboard since the last tick means the
      // payload cannot have changed, so the full read is skipped entirely.
      final changeCount = await _readClipboardChangeCount();
      if (changeCount != null &&
          (changeCount == _lastClipboardChangeCount ||
              changeCount == _lastEmptyChangeCount)) {
        return;
      }

      // Read clipboard using ClipboardService (supports all formats)
      final clipboardContent = await _clipboardService.read();
      if (_clipboardWritesInProgress > 0 || _isDisposed) return;

      // The counter is committed only once the read has actually produced
      // something. read() catches its own failures and returns empty - a
      // provider that is briefly unavailable, an image callback that throws -
      // and recording the counter before that point retired the tick anyway:
      // every later tick saw the same counter, skipped the read, and that copy
      // was never auto-sent unless the user copied something else. Leaving the
      // counter alone keeps a failed read retryable on the next tick.
      if (clipboardContent.isEmpty) {
        // Remembered separately so an empty read is retried once per NEW
        // counter value rather than never or forever. Leaving the counter
        // untouched kept a genuinely undecodable clipboard item - a flavour
        // read() cannot handle - doing the full pasteboard read, which for a
        // copied file means re-reading it from disk, on every 5-second tick
        // for as long as it stayed on the pasteboard.
        _lastEmptyChangeCount = changeCount;
        return;
      }
      if (changeCount != null) {
        _lastClipboardChangeCount = changeCount;
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
    } else if (content.hasFile) {
      final bytes = content.fileBytes!;
      // Use partial hash for large files (>1MB)
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

  /// Calculate partial hash for large content, much faster than hashing
  /// multi-MB payloads in full.
  ///
  /// Samples the head, the MIDDLE and the tail, plus the length. Head + tail
  /// alone collide on exactly the payloads this app sees most: two screenshots
  /// of the same window differ only in the middle, so the second was treated as
  /// a duplicate and never sent. The middle sample is what makes that case
  /// distinguishable; this is still a heuristic, not a full digest.
  String _partialHash(Uint8List bytes) {
    const chunkSize = 4096;
    final length = bytes.length;

    final head = bytes.sublist(0, chunkSize.clamp(0, length));
    final tail = length > chunkSize ? bytes.sublist(length - chunkSize) : head;

    final midStart = ((length - chunkSize) ~/ 2).clamp(0, length);
    final middle = length > chunkSize * 2
        ? bytes.sublist(midStart, (midStart + chunkSize).clamp(0, length))
        : head;

    final builder = BytesBuilder(copy: false)
      ..add(head)
      ..add(middle)
      ..add(tail)
      ..add(utf8.encode(length.toString()));
    return md5.convert(builder.takeBytes()).toString();
  }

  /// URL shortening, when the setting is on and the clip is a URL.
  Future<String> _applyUrlShortening(String content) async {
    final urlShortener = _urlShortenerService;
    if (urlShortener == null) return content;

    final autoShortenEnabled = await _settingsService.getAutoShortenUrls();
    if (!autoShortenEnabled || !urlShortener.isUrl(content)) return content;

    return urlShortener.shortenUrl(content);
  }

  /// The shared body of the three auto-send paths.
  ///
  /// Deduplication, target resolution, the send timestamp, the UI callback and
  /// both toasts are identical for text, images and files - only the hash and
  /// the repository call differ. This existed as three ~80-line copies,
  /// including three copies of the "to N device types" ladder, so every change
  /// to targeting or to the toast wording had to be made three times and the
  /// copies had already begun to drift.
  Future<void> _autoSend({
    required String noun,
    required String contentHash,
    required Future<ClipboardItem> Function(_AutoSendContext context) insert,
    required String Function(String targetText) message,
    required String failureMessage,
    void Function(_AutoSendContext context)? afterInsert,
  }) async {
    try {
      final userId = _supabaseClient.auth.currentUser?.id;
      if (userId == null) return;

      if (contentHash == _lastSentContentHash) {
        debugPrint('[ClipboardSyncService] Skipping duplicate $noun');
        return;
      }
      _lastSentContentHash = contentHash;

      final targetDevices = await _settingsService.getAutoSendTargetDevices();
      final context = _AutoSendContext(
        userId: userId,
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        deviceName: ClipboardRepository.getCurrentDeviceName(),
        // null rather than an empty list: the repository reads null as
        // "every device".
        targetDeviceTypes: targetDevices.isEmpty
            ? null
            : targetDevices.toList(),
      );

      final result = await insert(context);

      // Push notification is triggered by the database webhook
      // (send-clipboard-notification), so there is nothing to invoke here.
      afterInsert?.call(context);

      _lastSendTime = DateTime.now();
      onClipboardSent?.call(result);

      _notify(
        (n) => n.showToast(
          message: message(_describeTargets(targetDevices)),
          type: NotificationType.success,
        ),
      );

      debugPrint(
        '[ClipboardSyncService] Auto-sent $noun to '
        '${targetDevices.isEmpty ? "all devices" : targetDevices.join(", ")}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send $noun failed: $e');
      _notify(
        (n) =>
            n.showToast(message: failureMessage, type: NotificationType.error),
      );
    }
  }

  /// How the destination is described in a toast.
  static String _describeTargets(Set<String> targets) =>
      switch (targets.length) {
        0 => 'all devices',
        1 => targets.first,
        _ => '${targets.length} device types',
      };

  /// Auto-send clipboard content
  Future<void> _autoSendClipboard(String content) async {
    final String processedContent;
    try {
      processedContent = await _applyUrlShortening(content);
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send content failed: $e');
      _notify(
        (n) => n.showToast(
          message: 'Auto-send failed',
          type: NotificationType.error,
        ),
      );
      return;
    }

    await _autoSend(
      noun: 'content',
      contentHash: _calculateContentHash(processedContent),
      insert: (context) => _clipboardRepository.insert(
        ClipboardItem(
          id: '0',
          userId: context.userId,
          content: processedContent,
          deviceName: context.deviceName,
          deviceType: context.deviceType,
          targetDeviceTypes: context.targetDeviceTypes,
          createdAt: DateTime.now(),
        ),
      ),
      message: (targets) => 'Auto-sent to $targets',
      failureMessage: 'Auto-send failed',
      afterInsert: (context) {
        // Non-blocking. processedContent is plaintext - insert() encrypts
        // inside the repository.
        _fireIntegrations(
          content: processedContent,
          deviceType: context.deviceType,
          direction: 'sent',
        );
      },
    );
  }

  /// Auto-send image content
  Future<void> _autoSendImage(Uint8List imageBytes, String mimeType) async {
    final contentType = ContentType.fromMimeType(mimeType);
    if (contentType == null || !contentType.isImage) {
      debugPrint('[ClipboardSyncService] Unsupported image type: $mimeType');
      return;
    }

    final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);

    await _autoSend(
      noun: 'image',
      contentHash: _calculateClipboardContentHash(
        ClipboardContent.image(imageBytes, mimeType),
      ),
      insert: (context) => _clipboardRepository.insertImage(
        userId: context.userId,
        deviceType: context.deviceType,
        deviceName: context.deviceName,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: context.targetDeviceTypes,
      ),
      message: (targets) => 'Auto-sent image ($sizeKB KB) to $targets',
      failureMessage: 'Auto-send image failed',
    );
  }

  /// Auto-send file content
  Future<void> _autoSendFile(
    Uint8List fileBytes,
    String filename,
    String? mimeType,
  ) async {
    final fileTypeInfo = FileTypeService.instance.detectFromBytes(
      fileBytes,
      filename,
    );
    final sizeKB = (fileBytes.length / 1024).toStringAsFixed(1);

    await _autoSend(
      noun: 'file',
      contentHash: _calculateClipboardContentHash(
        ClipboardContent.file(fileBytes, filename, mimeType),
      ),
      insert: (context) => _clipboardRepository.insertFile(
        userId: context.userId,
        deviceType: context.deviceType,
        deviceName: context.deviceName,
        fileBytes: fileBytes,
        mimeType: mimeType ?? fileTypeInfo.mimeType,
        contentType: fileTypeInfo.contentType,
        originalFilename: filename,
        targetDeviceTypes: context.targetDeviceTypes,
      ),
      message: (targets) =>
          'Auto-sent file "$filename" ($sizeKB KB) to $targets',
      failureMessage: 'Auto-send file failed',
    );
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
    _lastClipboardModificationTime = clock.now();
  }

  /// Watch for the user changing the clipboard in any app, so smart
  /// auto-receive knows whether a received clip would overwrite something
  /// they just copied.
  ///
  /// Staleness was first measured from copies made in GhostCopy's history,
  /// through [updateClipboardModificationTime]. A refactor dropped those
  /// calls, after which only GhostCopy's own auto-copies set the time: smart
  /// behaved like always, and a second clip inside the window stayed
  /// uncopied. This reads the clipboard's change counter (see
  /// [_readClipboardChangeCount]) - one integer, never the contents - every
  /// thirty seconds, and stamps the time whenever it moves for any reason but
  /// GhostCopy writing. That covers copies in every app, not only GhostCopy's,
  /// on macOS and Windows; elsewhere only the history-copy hook applies.
  ///
  /// Thirty, not five: the smart decision reads the counter again itself
  /// before copying anything, so the sample only has to date a change to
  /// within the stale window, which is minutes long. Runs only while
  /// auto-receive is smart - see [refreshClipboardActivityWatch].
  @visibleForTesting
  void startClipboardActivityWatch() {
    if (_activityTimer != null ||
        _isDisposed ||
        !(Platform.isMacOS || Platform.isWindows)) {
      return;
    }
    unawaited(_checkClipboardActivity());
    _activityTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkClipboardActivity(),
    );
  }

  /// Run the watch only when something reads it: auto-receive set to smart.
  /// Always and never ignore staleness, and a timer waking the app every few
  /// seconds for nothing is what the tray's near-zero-CPU rule forbids.
  @override
  Future<void> refreshClipboardActivityWatch() async {
    if (_isDisposed) return;
    final behavior = await _settingsService.getAutoReceiveBehavior();
    if (_isDisposed) return;
    if (behavior == AutoReceiveBehavior.smart) {
      startClipboardActivityWatch();
    } else {
      stopClipboardActivityWatch();
    }
  }

  /// Stopped around screen lock and system sleep, with everything else the
  /// lifecycle pauses.
  @override
  void stopClipboardActivityWatch() {
    _activityTimer?.cancel();
    _activityTimer = null;
    // The next start takes a fresh baseline: a change made while nothing was
    // watching has an unknown age, and unknown counts as stale.
    _activityChangeCount = null;
  }

  Future<void> _checkClipboardActivity() async {
    if (_clipboardWritesInProgress > 0 || _isDisposed) return;
    final count = await _readClipboardChangeCount();
    if (count == null || _clipboardWritesInProgress > 0 || _isDisposed) return;
    final previous = _activityChangeCount;
    _activityChangeCount = count;
    // The first reading is only a baseline: a copy made before launch has an
    // unknown age, and unknown counts as stale.
    if (previous != null && count != previous) {
      _lastClipboardModificationTime = clock.now();
    }
  }

  /// Notify service that content was manually sent via UI
  @override
  void notifyManualSend(String content, {ClipboardContent? clipboardContent}) {
    if (_isDisposed) return;
    _recordClipboardContent(content, clipboardContent: clipboardContent);
    if (!(clipboardContent?.hasImage ?? false) &&
        !(clipboardContent?.hasFile ?? false) &&
        content.isNotEmpty) {
      _fireIntegrations(
        content: content,
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        direction: 'sent',
      );
    }
  }

  void _recordClipboardContent(
    String content, {
    ClipboardContent? clipboardContent,
  }) {
    final effectiveClipboardContent =
        clipboardContent ??
        (content.isNotEmpty
            ? ClipboardContent.text(content)
            : const ClipboardContent.empty());

    // Align monitor dedupe with the same hashing strategy used in
    // _checkClipboardForAutoSend (md5 / partial hash by payload type and size).
    final monitorHash = _calculateClipboardContentHash(
      effectiveClipboardContent,
    );
    if (monitorHash.isNotEmpty) {
      _lastMonitoredClipboard = monitorHash;
    }

    // Keep auto-send dedupe aligned with the dedicated send-path hashes.
    if (effectiveClipboardContent.hasImage ||
        effectiveClipboardContent.hasFile) {
      if (monitorHash.isNotEmpty) {
        _lastSentContentHash = monitorHash;
      }
    } else {
      final textToHash = effectiveClipboardContent.text ?? content;
      _lastSentContentHash = _calculateContentHash(textToHash);
    }

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
    _autoReceiveDebounceTimer?.cancel();
    _pendingAutoReceiveRecord = null;
    _lastPolledItemId = null;
    _lastMonitoredClipboard = '';
    _lastClipboardChangeCount = null;
    _lastEmptyChangeCount = null;
    _lastSentContentHash = '';

    // Subscribe with new user ID (no need to disconnect - auth token updates automatically)
    _subscribeToRealtimeUpdates();
  }

  /// Poll for new clipboard items
  Future<void> _pollForNewClipboards() async {
    try {
      debugPrint('[ClipboardSync] 🔍 Polling for new items...');

      final userId = _supabaseClient.auth.currentUser?.id;
      final latestId = await _clipboardRepository.getLatestItemId();
      if (_isDisposed ||
          userId != _supabaseClient.auth.currentUser?.id ||
          latestId == null ||
          latestId == _lastPolledItemId) {
        return;
      }

      // Fetch/decrypt only when the ID changes. The receive path rechecks
      // ownership, sender and targets before touching the system clipboard.
      _lastPolledItemId = latestId;
      await _handleSmartAutoReceive({'id': latestId});

      // Notify UI to refresh
      onClipboardReceived?.call();
    } on Exception catch (e) {
      debugPrint('[ClipboardSync] ❌ Polling error: $e');
    }
  }

  bool _isDisposed = false;

  /// Fire webhook (non-blocking with tracking for clean disposal - Fix #10)
  /// Hand a clip to the external integrations.
  ///
  /// Both fire on clips this device SENDS and on clips it RECEIVES. They used
  /// to hang off the auto-send path alone, so a clip sent from the Spotlight
  /// by hand, or one arriving from the phone, reached neither - while the
  /// settings toggle said "Send clipboard data to external services" and the
  /// point of the Obsidian vault is to be a complete capture log.
  ///
  /// [content] must be plaintext. It is on both paths and neither needs
  /// unwrapping: insert() encrypts inside the repository, so a caller on the
  /// send side still holds the readable text, and items coming back out have
  /// already been through _decryptItems(). Passing ciphertext here would fill
  /// the vault with unreadable blobs.
  ///
  /// [deviceType] is whichever device the clip came from, so a received clip
  /// is attributed to the phone that sent it rather than to this Mac.
  void _fireIntegrations({
    required String content,
    required String deviceType,
    required String direction,
  }) {
    _fireWebhook(content, deviceType, direction);
    _appendToObsidian(content, deviceType, direction);
  }

  void _fireWebhook(String content, String deviceType, String direction) {
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
          // Which way the clip was going. The hook fires on both now, and a
          // consumer that only wants outbound clips cannot tell them apart
          // from deviceType alone.
          'direction': direction,
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
  void _appendToObsidian(String content, String deviceType, String direction) {
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
            deviceType: deviceType,
            direction: direction,
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

    stopClipboardActivityWatch();

    _autoReceiveDebounceTimer?.cancel();
    _autoReceiveDebounceTimer = null;

    _pollingTimer?.cancel();
    _pollingTimer = null;

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

/// The per-send values every auto-send path needs.
///
/// Resolved once in [ClipboardSyncService._autoSend] and handed to the insert
/// closure, so the "empty set means every device" rule is expressed in exactly
/// one place instead of at each call site.
class _AutoSendContext {
  const _AutoSendContext({
    required this.userId,
    required this.deviceType,
    required this.deviceName,
    required this.targetDeviceTypes,
  });

  final String userId;
  final String deviceType;
  final String? deviceName;
  final List<String>? targetDeviceTypes;
}
