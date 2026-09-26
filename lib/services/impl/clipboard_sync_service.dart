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
import '../../utils/html_text.dart';
import '../../utils/platform_label.dart';
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

  /// Built before this service in main.dart, so a clip that arrives during
  /// startup is announced like any other; null only in tests.
  final INotificationService? _notificationService;

  final IGameModeService? _gameModeService;
  final IUrlShortenerService? _urlShortenerService;
  final IWebhookService? _webhookService;
  final IObsidianService? _obsidianService;

  // Realtime subscription
  RealtimeChannel? _realtimeChannel;

  /// Rejoin backoff, in seconds, indexed by consecutive failures. Capped so a
  /// long outage settles at one attempt a minute rather than hammering.
  static const List<int> _realtimeBackoffSeconds = [2, 5, 15, 30, 60];
  Timer? _realtimeRetryTimer;
  int _realtimeRetries = 0;

  /// Tracked from the subscribe callback rather than read off the channel:
  /// RealtimeChannel.isJoined is package-internal, and this is the same
  /// information from the one source that is told about every transition.
  bool _realtimeJoined = false;

  /// Which channel status callbacks are still listened to.
  ///
  /// Bumped on every subscribe and every deliberate teardown. unsubscribe()
  /// reports `closed` through the same callback a dying socket does, so
  /// without this a pause for sleep, lock or tray polling read as a failure
  /// and rejoined two seconds later - the socket back open while the app was
  /// meant to be asleep.
  int _realtimeGeneration = 0;

  /// Set when a channel joins, until the catch-up poll that follows has run.
  ///
  /// That poll exists to find what was inserted while the channel was down,
  /// so what it finds is no evidence against the channel that just joined.
  bool _realtimeCatchUpPending = false;

  /// When a rejoin was last attempted from [ensureRealtimeConnected].
  ///
  /// A channel that never reaches `subscribed` - an unreachable server, a
  /// revoked session - would otherwise be rejoined on every single poll tick,
  /// because "not joined" stays true the whole time. The backoff in
  /// _scheduleRealtimeResubscribe covers the callback path; this covers the
  /// path that has no callback to wait for.
  DateTime? _lastRejoinAttempt;
  static const Duration _rejoinCooldown = Duration(seconds: 30);

  // Clipboard monitoring
  Timer? _clipboardMonitorTimer;
  String _lastMonitoredClipboard = '';
  bool _isMonitoring = false;
  bool _isCheckingClipboard = false;

  @override
  bool get isMonitoring => _isMonitoring;

  // Polling mode state
  Timer? _pollingTimer;
  bool _isPolling = false;

  /// A poll asked for while one was running - the catch-up on resume, say.
  /// Run once the current one finishes rather than dropped: the running poll
  /// may already have read the newest id, and a row after it would otherwise
  /// wait for the next timer tick, or forever once realtime has taken over.
  bool _pollRequested = false;

  /// The newest clipboard row already seen, by realtime or by a poll, so a
  /// poll never runs a clip through auto-receive a second time.
  String? _lastPolledItemId;

  /// Whether [_lastPolledItemId] has been established for this account,
  /// including as "no clips at all". Null alone cannot say: an empty account
  /// looked exactly like a baseline never taken, so a first clip that landed
  /// while realtime was paused was adopted as the baseline on resume and
  /// never delivered.
  bool _baselineReady = false;

  /// Rows already handed to auto-receive, by realtime or by a poll. Around a
  /// switch back to realtime the catch-up poll and the new subscription can
  /// both see the same row; whichever claims it first delivers it. Bounded:
  /// only the handoff needs it.
  final _claimedIds = <String>{};
  static const _maxClaimedIds = 64;

  /// Ids whose fetch threw, for the poll that asked to wind back and retry.
  final _failedFetchIds = <String>{};

  /// Claim [id] for delivery. False if the other path already has it.
  bool _claim(String id) {
    if (!_claimedIds.add(id)) return false;
    if (_claimedIds.length > _maxClaimedIds) {
      _claimedIds.remove(_claimedIds.first);
    }
    return true;
  }

  // Auto-receive debouncing
  Timer? _autoReceiveDebounceTimer;

  // Rate limiting for send operations
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  int _clipboardWritesInProgress = 0;

  // Pending background operations for clean shutdown (Fix #10)

  // Content deduplication
  String _lastSentContentHash = '';

  /// When the user last changed the clipboard themselves, as far as this
  /// service can tell. Smart auto-receive copies a received clip only once
  /// this is older than the stale duration, so it never overwrites something
  /// the user just copied. Null until a change has been seen, which counts as
  /// stale.
  DateTime? _lastClipboardModificationTime;

  /// Whether the activity watch is running; see [startClipboardActivityWatch].
  bool _watching = false;

  /// Samples the pasteboard change counter where it is not pushed (macOS).
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

    // Nothing seen yet - launch, or an account switch: whatever is newest now
    // predates this subscription and was never auto-received, so the first
    // poll must not treat it as new either.
    if (!_baselineReady) unawaited(_seedPollBaseline(userId));

    final generation = ++_realtimeGeneration;
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
            handleRealtimeInsert(payload.newRecord);
          },
        )
        .subscribe(
          (status, error) =>
              _onRealtimeStatus(generation, status, error, userId),
        );

    debugPrint('[ClipboardSyncService] Realtime subscription active');
  }

  /// React to the channel's own view of its health.
  ///
  /// subscribe() was previously called with no callback at all, so nothing in
  /// the app ever learned that realtime had died - and nothing resubscribed.
  /// Delivery silently fell back to the five-minute poll, which is exactly
  /// what "the clip arrived five minutes later" was. It showed up on Windows
  /// first because Windows throttles a background process hard enough for the
  /// socket's heartbeat to lapse; the same socket dies on any platform across
  /// a sleep, a network change or a server-side restart.
  void _onRealtimeStatus(
    int generation,
    RealtimeSubscribeStatus status,
    Object? error,
    String userId,
  ) {
    if (_isDisposed) return;
    // A channel this service let go of on purpose - paused, replaced, or
    // bound to an account that has since changed. Its `closed` is the
    // unsubscribe it was asked for, not a failure.
    if (generation != _realtimeGeneration) return;
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        debugPrint('[ClipboardSyncService] ✅ Realtime subscribed');
        _realtimeJoined = true;
        _realtimeRetries = 0;
        _realtimeRetryTimer?.cancel();
        _realtimeRetryTimer = null;
        // Anything inserted while the channel was down was never delivered,
        // so catch up rather than waiting for the next poll.
        if (_baselineReady) {
          _realtimeCatchUpPending = true;
          unawaited(_pollForNewClipboards(queueIfBusy: true));
        }
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
      case RealtimeSubscribeStatus.closed:
        _realtimeJoined = false;
        debugPrint(
          '[ClipboardSyncService] ⚠️ Realtime ${status.name}'
          '${error != null ? ': $error' : ''}',
        );
        _scheduleRealtimeResubscribe(userId);
    }
  }

  /// Rejoin after a backoff, so a server that is down or an account that has
  /// lost its session cannot turn into a reconnect loop.
  void _scheduleRealtimeResubscribe(String userId) {
    if (_isDisposed || _realtimeRetryTimer != null) return;

    final seconds =
        _realtimeBackoffSeconds[_realtimeRetries.clamp(
          0,
          _realtimeBackoffSeconds.length - 1,
        )];
    _realtimeRetries++;
    debugPrint(
      '[ClipboardSyncService] Rejoining realtime in ${seconds}s '
      '(attempt $_realtimeRetries)',
    );
    _realtimeRetryTimer = Timer(Duration(seconds: seconds), () {
      _realtimeRetryTimer = null;
      if (_isDisposed) return;
      // The account can have changed while this was pending.
      if (_supabaseClient.auth.currentUser?.id != userId) return;
      _dropRealtimeChannel();
      _subscribeToRealtimeUpdates();
    });
  }

  /// Called when a poll delivered a clip that realtime should have.
  ///
  /// A channel can die without saying so - Windows throttles a background
  /// process hard enough for the socket's heartbeat to lapse, and what comes
  /// back is silence rather than an error. There is no status to react to and
  /// no way to ask, so the only honest signal is this one: the fallback found
  /// something the channel was supposed to deliver, which proves it is not
  /// delivering. Checking on every poll tick instead would rejoin constantly
  /// while a server is unreachable, for no evidence at all.
  void _noteRealtimeMissedAClip() {
    if (!_realtimeJoined) return;
    debugPrint(
      '[ClipboardSyncService] Poll found a clip realtime missed - rejoining',
    );
    _realtimeJoined = false;
    ensureRealtimeConnected();
  }

  /// Rejoin now if the channel is not currently joined.
  ///
  /// For the moments where the socket is most likely to have died without
  /// anyone being told: waking from sleep, unlocking, or simply the next poll
  /// noticing that realtime has not spoken for a while.
  @override
  void ensureRealtimeConnected() {
    if (_isDisposed) return;
    if (_realtimeChannel != null && _realtimeJoined) return;
    // Nothing to rejoin as, and _subscribeToRealtimeUpdates would have
    // nothing to filter on.
    if (_supabaseClient.auth.currentUser == null) return;
    // A rejoin is already pending on its backoff; let it run.
    if (_realtimeRetryTimer != null) return;

    final last = _lastRejoinAttempt;
    final now = clock.now();
    if (last != null && now.difference(last) < _rejoinCooldown) return;
    _lastRejoinAttempt = now;

    debugPrint('[ClipboardSyncService] Realtime not joined - rejoining now');
    _realtimeRetryTimer?.cancel();
    _realtimeRetryTimer = null;
    _realtimeRetries = 0;
    try {
      _dropRealtimeChannel();
      _subscribeToRealtimeUpdates();
    } on Object catch (e) {
      // This is called from the polling timer, and polling is the fallback
      // that delivers while realtime is down. A failed rejoin must never be
      // able to take that down with it.
      debugPrint('[ClipboardSyncService] Rejoin attempt failed: $e');
    }
  }

  /// Let go of the current channel on purpose.
  ///
  /// The generation moves first, so the `closed` that unsubscribe() reports -
  /// synchronously, when the socket is already down - is ignored rather than
  /// scheduling a rejoin.
  void _dropRealtimeChannel() {
    _realtimeGeneration++;
    _realtimeJoined = false;
    _realtimeCatchUpPending = false;
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    channel?.unsubscribe();
  }

  Future<void> _seedPollBaseline(String userId) async {
    try {
      final latest = await _clipboardRepository.getLatestItemId();
      // A realtime insert or a poll that landed first is newer than this.
      if (_isDisposed ||
          _baselineReady ||
          _lastPolledItemId != null ||
          _supabaseClient.auth.currentUser?.id != userId) {
        return;
      }
      _lastPolledItemId = latest;
      _baselineReady = true;
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Could not seed poll baseline: $e');
    }
  }

  /// One clipboard row inserted for this account, as Realtime delivers it.
  @visibleForTesting
  void handleRealtimeInsert(Map<String, dynamic> record) {
    // Realtime has seen this row, so the polling fallback must not treat it
    // as new when it takes over - it would hand the clip to the integrations
    // a second time.
    final id = record['id']?.toString();
    if (id != null) {
      _lastPolledItemId = id;
      _baselineReady = true;
      // The catch-up poll got here first: it is already being delivered.
      if (!_claim(id)) {
        onClipboardReceived?.call();
        return;
      }
    }

    if (_isForThisDevice(
      record['device_name'] as String?,
      ClipboardItem.parseTargetDeviceTypes(record['target_device_type']),
    )) {
      _debouncedAutoReceive(record);
    }

    // Notify UI to refresh history
    onClipboardReceived?.call();
  }

  /// Debounce auto-receive to prevent clipboard thrashing.
  ///
  /// Only the clipboard write is debounced. Every record is still fetched and
  /// handed to the integrations as it arrives, because the Obsidian vault and
  /// the webhook are meant to see every clip - two clips 300ms apart must both
  /// land there even though only the second one is worth copying.
  void _debouncedAutoReceive(Map<String, dynamic> record) {
    final id = record['id']?.toString();
    if (id == null || _isDisposed) return;
    final item = _receiveItem(id);

    _autoReceiveDebounceTimer?.cancel();
    _autoReceiveDebounceTimer = Timer(
      const Duration(milliseconds: 500),
      () => _handleSmartAutoReceive(item),
    );
  }

  /// Fetch a received clip and deliver it to the integrations.
  ///
  /// Resolves to null when the clip is not this device's to receive, or the
  /// account changed while it was being fetched. Never throws: the result can
  /// sit unawaited behind a debounce that gets cancelled.
  Future<ClipboardItem?> _receiveItem(String id) async {
    try {
      final userId = _supabaseClient.auth.currentUser?.id;
      if (userId == null || _isDisposed) return null;
      final item = await _clipboardRepository.getById(id);
      if (item == null ||
          _isDisposed ||
          _supabaseClient.auth.currentUser?.id != userId ||
          !_canReceive(item)) {
        return null;
      }
      _deliverReceived(item);
      return item;
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Receive fetch failed: $e');
      // Not delivered, so not claimed: the other path, or the next poll, may
      // still try it. A claim held through a failed fetch lost the clip for
      // good, since the competing path had already stepped aside.
      _claimedIds.remove(id);
      _failedFetchIds.add(id);
      return null;
    }
  }

  /// Hand a received text clip to the integrations. Independent of the
  /// clipboard copy policy. HTML goes out as text, matching what the sending
  /// device delivered: its side hands over the clipboard's plain-text
  /// flavour, not markup.
  void _deliverReceived(ClipboardItem item) {
    if (item.contentType == ContentType.html ||
        item.contentType == ContentType.text ||
        item.contentType == ContentType.markdown) {
      _fireIntegrations(
        content: item.content,
        deviceType: item.deviceType,
        direction: 'received',
        isHtml: item.contentType == ContentType.html,
      );
    }
  }

  /// Handle smart auto-receive logic with support for multiple content types
  Future<void> _handleSmartAutoReceive(
    Future<ClipboardItem?> pendingItem,
  ) async {
    try {
      final item = await pendingItem;
      if (item == null || _isDisposed || !_canReceive(item)) return;
      // Product names in what the user reads: "macOS", not "macos".
      final deviceType = platformLabel(item.deviceType);

      // Load auto-receive behavior from settings
      final autoReceiveBehavior = await _settingsService
          .getAutoReceiveBehavior();
      final staleDurationMinutes = await _settingsService
          .getClipboardStaleDurationMinutes();
      if (_isDisposed || !_canReceive(item)) return;

      // Whether the user's own last copy is old enough to overwrite.
      //
      // On macOS the watch samples every 30 seconds, and on Windows a pushed
      // change may still be on its way, so a copy made just now could be
      // invisible here and get overwritten - the very thing smart receive
      // exists to prevent. The counter is read now; a change not yet seen
      // counts as a copy made this moment.
      // clock rather than DateTime so tests can move time past the window.
      Future<bool> smartAllowsCopy() async {
        await _checkClipboardActivity();
        final lastModified = _lastClipboardModificationTime;
        final stale =
            lastModified == null ||
            clock.now().difference(lastModified) >=
                Duration(minutes: staleDurationMinutes);
        debugPrint(
          '[ClipboardSyncService] Smart check: last user copy '
          '$lastModified, window $staleDurationMinutes min, stale $stale',
        );
        return stale;
      }

      final shouldAutoCopy = switch (autoReceiveBehavior) {
        AutoReceiveBehavior.always => true,
        AutoReceiveBehavior.never => false,
        AutoReceiveBehavior.smart => await smartAllowsCopy(),
      };
      if (_isDisposed || !_canReceive(item)) return;

      debugPrint(
        '[ClipboardSyncService] Auto-Receive Behavior: ${autoReceiveBehavior.name}',
      );
      debugPrint('[ClipboardSyncService] Should Auto-Copy: $shouldAutoCopy');

      // Offer the clip through a clickable notification instead of copying it.
      void offerCopy() {
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
          _notificationService?.showClickableToast(
            message: message,
            actionLabel: 'Copy',
            duration: const Duration(seconds: 5),
            onAction: () async {
              try {
                // The user picked this clip, so smart receive must now
                // guard it like any other copy of theirs.
                if (await _copyItemToClipboard(item)) {
                  updateClipboardModificationTime();
                }
                debugPrint('[ClipboardSyncService] Copied from notification');
              } on Exception catch (e) {
                debugPrint('[ClipboardSyncService] Failed to copy: $e');
                _notificationService.showToast(
                  message: 'Failed to copy',
                  type: NotificationType.error,
                );
              }
            },
          );
        }
      }

      if (shouldAutoCopy) {
        try {
          final copied = await _copyItemToClipboard(
            item,
            // The same decision, taken again right before the media is
            // written: a copy the user made while it downloaded must win.
            stillWanted: autoReceiveBehavior == AutoReceiveBehavior.smart
                ? smartAllowsCopy
                : null,
          );
          // Signed out, switched account or shut down meanwhile: the clip is
          // no longer this session's to offer.
          if (_isDisposed || !_canReceive(item)) return;
          if (!copied) {
            // The user copied something while the media downloaded: their
            // copy stays, and the clip is offered instead.
            debugPrint(
              '[ClipboardSyncService] Clipboard changed during download - '
              'offering the clip instead',
            );
            offerCopy();
            return;
          }
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
      } else {
        offerCopy();
      }
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-receive failed: $e');
    }
  }

  bool _canReceive(ClipboardItem item) =>
      item.userId == _supabaseClient.auth.currentUser?.id &&
      _isForThisDevice(item.deviceName, item.targetDeviceTypes);

  /// Whether a clip sent by [senderName] to [targets] is this device's to
  /// receive. The realtime filter and [_canReceive] share it, so the two
  /// paths cannot drift apart again.
  ///
  /// The sender check is a plain inequality, deliberately: null guards that
  /// used to be here made it false whenever either side had no name, and
  /// mobile sends device_name: null on every path. That meant a clip sent
  /// from the phone never triggered auto-receive on the desktop - the
  /// Mobile -> Desktop half of sync - and it only appeared to work because
  /// the polling fallback compared the same two values without the guards.
  ///
  /// Known limit: this identifies devices by name, so two machines sharing a
  /// hostname will not receive from each other. Fixing that needs a device id
  /// on the clipboard row.
  static bool _isForThisDevice(String? senderName, List<String>? targets) =>
      senderName != ClipboardRepository.getCurrentDeviceName() &&
      (targets == null ||
          targets.contains(ClipboardRepository.getCurrentDeviceType()));

  /// Copy a clipboard item to the system clipboard, supporting multiple content types
  ///
  /// Uses super_clipboard for full format support:
  /// - Plain text (copied as plain text)
  /// - Rich text (HTML/Markdown - HTML copied with plain text fallback)
  /// - Images (PNG/JPEG/GIF - downloaded from storage and copied as image)
  /// - Files (PDF, DOC, ZIP, etc. - downloaded to temp, path copied to clipboard)
  /// - Encrypted content (already decrypted by repository)
  ///
  /// [stillWanted] is asked right before a downloaded image or file is
  /// written. The smart decision is taken before the download starts, and a
  /// download can take seconds; a copy the user makes meanwhile must win.
  /// Returns whether anything was written - false also when the service was
  /// disposed or the clip stopped being this account's, which callers check
  /// for themselves before offering it instead.
  Future<bool> _copyItemToClipboard(
    ClipboardItem item, {
    Future<bool> Function()? stillWanted,
  }) async {
    if (_isDisposed || !_canReceive(item)) return false;
    // Asked again once a download finishes: signing out or switching account
    // while it ran must not leave the old account's clip on the clipboard.
    Future<bool> wanted() async =>
        !_isDisposed &&
        _canReceive(item) &&
        (stillWanted == null || await stillWanted());
    _clipboardWritesInProgress++;
    var writtenContent = const ClipboardContent.empty();
    try {
      switch (item.contentType) {
        case ContentType.text:
          // Plain text - copy directly
          await _landWrite(() => _clipboardService.writeText(item.content));
          writtenContent = ClipboardContent.text(item.content);

        case ContentType.html:
          // HTML - copy with plain text fallback (super_clipboard handles both)
          await _landWrite(() => _clipboardService.writeHtml(item.content));
          writtenContent = ClipboardContent.html(item.content);
          debugPrint('[ClipboardSyncService] Copied HTML to clipboard');

        case ContentType.markdown:
          // Markdown - copy as plain text (markdown isn't standard clipboard format)
          await _landWrite(() => _clipboardService.writeText(item.content));
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

          if (!await wanted()) return false;

          // Copy image to clipboard using super_clipboard (full native support)
          await _landWrite(() => _clipboardService.writeImage(imageBytes));
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

            if (!await wanted()) return false;

            // Copy file path to clipboard
            await _landWrite(
              () => _clipboardService.writeFilePath(tempFile.path),
            );
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
      return true;
    } finally {
      _clipboardWritesInProgress--;
    }
  }

  /// GhostCopy writes issued but whose counter bump is not yet absorbed. The
  /// activity watch waits these out: a counter read in that gap cannot tell
  /// GhostCopy's change from the user's.
  final Set<Future<void>> _landingWrites = {};

  /// Bumped as each write starts landing, so a counter read that raced one is
  /// recognised and taken again.
  int _writeEpoch = 0;

  /// Run one clipboard write and absorb the counter bump it causes, so neither
  /// the activity watch nor auto-send mistakes GhostCopy's write for the user
  /// copying.
  ///
  /// The counter is read straight after the write, before anything else is
  /// awaited. It used to be read at the very end, after the read-back - which
  /// re-reads a whole file or image and can take hundreds of milliseconds -
  /// so a copy the user made in that gap was absorbed as GhostCopy's own and
  /// the next clip overwrote it. A write that throws absorbs nothing: a change
  /// the user made meanwhile is then the only change, and must count.
  Future<void> _landWrite(Future<void> Function() write) async {
    final landed = Completer<void>();
    _landingWrites.add(landed.future);
    _writeEpoch++;
    try {
      await write();
      final count = await _readClipboardChangeCount();
      if (count != null) {
        _activityChangeCount = count;
        // Auto-send's gate too: the write's content is already recorded, so
        // re-reading it - a whole image or file - on the next tick is waste.
        _lastClipboardChangeCount = count;
      }
    } finally {
      _landingWrites.remove(landed.future);
      landed.complete();
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

  /// The counter value the latest empty reads were taken at, and how many
  /// strikes they have. Once there are [_maxFailedReads], that exact
  /// pasteboard state is not read again while it is still there.
  int? _emptyReadChangeCount;
  int _emptyReads = 0;

  /// How many failed reads retire a counter value. A genuinely empty read -
  /// nothing read() can decode - retires it at once. A failed one does not:
  /// on Windows the read fails whenever another process, a clipboard manager
  /// or an RDP session, briefly holds the clipboard open, and retiring the
  /// value then meant that copy was never auto-sent unless the user copied
  /// something else. Three ticks ride out a transient lock, and still stop an
  /// item whose read keeps failing from being re-read every tick.
  static const _maxFailedReads = 3;

  /// Whether this platform answers [_clipboardChangeChannel]. Tests set it so
  /// the counter paths run on the Linux CI host.
  @visibleForTesting
  static bool? debugHasChangeCounter;

  static bool get _hasChangeCounter =>
      debugHasChangeCounter ?? (Platform.isMacOS || Platform.isWindows);

  /// Whether the platform pushes "changed" when the counter moves, so the
  /// activity watch needs no timer. Windows does; macOS cannot.
  @visibleForTesting
  static bool? debugCounterPushesChanges;

  static bool get _counterPushesChanges =>
      debugCounterPushesChanges ?? Platform.isWindows;

  Future<int?> _readClipboardChangeCount() async {
    if (!_hasChangeCounter) return null;
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
    if (_clipboardWritesInProgress > 0 || _isDisposed || _isCheckingClipboard) {
      return;
    }
    // A slow native read/upload can outlive the timer interval. Keep only one
    // payload in flight instead of accumulating reads and duplicate work.
    _isCheckingClipboard = true;
    try {
      // Nothing written to the pasteboard since the last tick means the
      // payload cannot have changed, so the full read is skipped entirely.
      final changeCount = await _readClipboardChangeCount();
      if (changeCount != null &&
          (changeCount == _lastClipboardChangeCount ||
              (changeCount == _emptyReadChangeCount &&
                  _emptyReads >= _maxFailedReads))) {
        return;
      }

      // Read clipboard using ClipboardService (supports all formats)
      final clipboardContent = await _clipboardService.read();
      if (_clipboardWritesInProgress > 0 || _isDisposed) return;

      // The counter is committed only once the read has actually produced
      // something, so a read that failed - a clipboard briefly held open by
      // another process, an image callback that throws - is retried on the
      // next tick rather than that copy never being auto-sent.
      if (clipboardContent.isEmpty) {
        // Remembered separately so the same empty state is not read forever:
        // a genuinely undecodable item - a flavour read() cannot handle - once,
        // a failing read up to [_maxFailedReads] times. Otherwise a copied
        // file read() could not use was re-read from disk every 5 seconds for
        // as long as it stayed on the pasteboard.
        if (changeCount != null) {
          final strikes = changeCount == _emptyReadChangeCount
              ? _emptyReads
              : 0;
          _emptyReads = clipboardContent.readFailed
              ? strikes + 1
              : _maxFailedReads;
          _emptyReadChangeCount = changeCount;
        }
        return;
      }
      if (changeCount != null) {
        _lastClipboardChangeCount = changeCount;
      }
      _emptyReadChangeCount = null;
      _emptyReads = 0;

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
    } finally {
      _isCheckingClipboard = false;
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

      _notificationService?.showToast(
        message: message(_describeTargets(targetDevices)),
        type: NotificationType.success,
      );

      debugPrint(
        '[ClipboardSyncService] Auto-sent $noun to '
        '${targetDevices.isEmpty ? "all devices" : targetDevices.join(", ")}',
      );
    } on Exception catch (e) {
      debugPrint('[ClipboardSyncService] Auto-send $noun failed: $e');
      _notificationService?.showToast(
        message: failureMessage,
        type: NotificationType.error,
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
      _notificationService?.showToast(
        message: 'Auto-send failed',
        type: NotificationType.error,
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
          // Auto-send screened the clipboard text before sending it; only a
          // shortened URL is new text.
          screened: processedContent == content,
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
  /// [_readClipboardChangeCount]) - one integer, never the contents - and
  /// stamps the time whenever it moves for any reason but GhostCopy writing.
  /// That covers copies in every app, not only GhostCopy's, on macOS and
  /// Windows; elsewhere only the history-copy hook applies.
  ///
  /// Windows tells us when the counter moves (WM_CLIPBOARDUPDATE, pushed as
  /// "changed"), so there the watch has no timer at all and costs nothing
  /// while the clipboard is left alone - in the tray or not. macOS has no
  /// such notification, so it samples every thirty seconds: the smart
  /// decision reads the counter again itself before copying anything, so a
  /// sample only has to date a change to within the stale window, which is
  /// minutes long. Runs only while auto-receive is smart - see
  /// [refreshClipboardActivityWatch].
  @visibleForTesting
  void startClipboardActivityWatch() {
    if (_watching || _isDisposed || !_hasChangeCounter) return;
    _watching = true;
    // A fresh baseline every start. A change made while nothing was watching
    // has an unknown age, and unknown counts as stale - but the absorb after
    // each write keeps updating the count while the watch is off, so without
    // this, switching to smart hours after an auto-copy compared against that
    // old value and dated the whole morning's copying to this moment.
    _activityChangeCount = null;
    if (_counterPushesChanges) {
      _clipboardChangeChannel.setMethodCallHandler(_onClipboardChangePushed);
    } else {
      _activityTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _checkClipboardActivity(),
      );
    }
    unawaited(_checkClipboardActivity());
  }

  Future<void> _onClipboardChangePushed(MethodCall call) async {
    if (call.method == 'changed') await _checkClipboardActivity();
  }

  /// Run the watch only when something reads it: auto-receive set to smart.
  /// Always and never ignore staleness, and a timer waking the app for nothing
  /// is what the tray's near-zero-CPU rule forbids.
  @override
  Future<void> refreshClipboardActivityWatch() async {
    if (_isDisposed) return;
    final generation = _watchGeneration;
    final behavior = await _settingsService.getAutoReceiveBehavior();
    // A stop that landed while settings were read wins: the lifecycle pauses
    // the watch on screen lock, and a refresh started by the unlock just
    // before must not restart it under the lock when it completes.
    if (_isDisposed || generation != _watchGeneration) return;
    if (behavior == AutoReceiveBehavior.smart) {
      startClipboardActivityWatch();
    } else {
      stopClipboardActivityWatch();
    }
  }

  /// Bumped by every stop, invalidating any refresh still reading settings.
  int _watchGeneration = 0;

  /// Stopped around screen lock and system sleep, with everything else the
  /// lifecycle pauses.
  @override
  void stopClipboardActivityWatch() {
    _watchGeneration++;
    final wasRunning = _watching;
    _watching = false;
    _activityTimer?.cancel();
    _activityTimer = null;
    if (wasRunning && _counterPushesChanges) {
      _clipboardChangeChannel.setMethodCallHandler(null);
    }
    // One last sample, so a copy made since the previous one - the address
    // copied ten seconds before locking the screen - is dated now rather
    // than lost, and a clip arriving right after unlock still leaves it be.
    if (wasRunning && !_isDisposed) unawaited(_sampleClipboardActivity());
  }

  /// Sample the counter if the watch is running; see [_sampleClipboardActivity].
  Future<void> _checkClipboardActivity() async {
    if (_watching) await _sampleClipboardActivity();
  }

  /// Read the counter and stamp [_lastClipboardModificationTime] if somebody
  /// other than GhostCopy moved it.
  ///
  /// A GhostCopy write that is landing is waited out rather than skipped:
  /// this used to return early whenever any received clip was in progress,
  /// so while an image downloaded, the next clip's staleness check did
  /// nothing and its text replaced a copy the user had just made. A download
  /// never touches the clipboard, so only the moment a write lands is
  /// ambiguous, and [_landWrite] marks exactly that.
  Future<void> _sampleClipboardActivity() async {
    while (!_isDisposed) {
      if (_landingWrites.isNotEmpty) {
        await Future.wait(List.of(_landingWrites));
        continue;
      }
      final epoch = _writeEpoch;
      final count = await _readClipboardChangeCount();
      if (count == null || _isDisposed) return;
      // A write started while the counter was read: that reading may predate
      // it, and storing it would undo the write's absorb. Read again.
      if (epoch != _writeEpoch) continue;
      final previous = _activityChangeCount;
      _activityChangeCount = count;
      // The first reading is only a baseline: a copy made before it has an
      // unknown age, and unknown counts as stale.
      if (previous != null && count != previous) {
        _lastClipboardModificationTime = clock.now();
      }
      return;
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
    // A rejoin still on its backoff would reopen the socket this is closing.
    _realtimeRetryTimer?.cancel();
    _realtimeRetryTimer = null;
    _realtimeRetries = 0;
    if (_realtimeChannel == null) return;

    debugPrint('[ClipboardSync] ⏸️  Pausing realtime subscription');
    _dropRealtimeChannel();
  }

  /// Resume realtime subscription
  @override
  void resumeRealtime() {
    if (_realtimeChannel != null) return; // Already active

    debugPrint('[ClipboardSync] ▶️  Resuming realtime subscription');
    _subscribeToRealtimeUpdates();

    // A subscription only sees rows inserted after it opens. Anything that
    // landed since the last poll - a file sent from Finder's context menu,
    // which inserts straight through the repository, or a clip from the
    // phone - was never delivered: not to the history, not to auto-receive,
    // not to the integrations. It showed up only once some later clip made
    // the history reload, minutes afterwards. One catch-up poll closes the
    // gap. With no baseline yet, _subscribeToRealtimeUpdates seeds one and
    // there is nothing to catch up on - but an empty account's baseline is
    // ready, and its first clip may be exactly what was missed.
    if (_baselineReady) unawaited(_pollForNewClipboards(queueIfBusy: true));
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

    // Unsubscribe from old realtime channel. A rejoin pending for the old
    // account would bail on its user check anyway; cancelling it lets the
    // new channel's failures start their own backoff.
    _realtimeRetryTimer?.cancel();
    _realtimeRetryTimer = null;
    _realtimeRetries = 0;
    _dropRealtimeChannel();
    _autoReceiveDebounceTimer?.cancel();
    _lastPolledItemId = null;
    _baselineReady = false;
    _claimedIds.clear();
    _failedFetchIds.clear();
    // A catch-up queued for the account just left must not run against this
    // one before its baseline is taken.
    _pollRequested = false;
    _lastMonitoredClipboard = '';
    _lastClipboardChangeCount = null;
    _emptyReadChangeCount = null;
    _emptyReads = 0;
    _lastSentContentHash = '';

    // Subscribe with new user ID (no need to disconnect - auth token updates automatically)
    _subscribeToRealtimeUpdates();
  }

  /// Poll for new clipboard items
  ///
  /// [queueIfBusy] is for the resume catch-up, which must not be lost to a
  /// poll already running. Timer ticks are not queued: the timer comes round
  /// again anyway, and queueing them stacked a burst of polls behind one slow
  /// request.
  Future<void> _pollForNewClipboards({bool queueIfBusy = false}) async {
    if (_isDisposed) return;
    if (_isPolling) {
      if (queueIfBusy) _pollRequested = true;
      return;
    }
    _isPolling = true;
    // Only a channel that was already joined when this poll began, and whose
    // catch-up has run, can be blamed for what the poll finds. Rows from
    // before the join were never that channel's to deliver.
    final canBlameRealtime = _realtimeJoined && !_realtimeCatchUpPending;
    _realtimeCatchUpPending = false;
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

      // Getting here means the newest row is one the poll has not seen. If
      // the channel believes it is subscribed, it should have delivered this
      // already - so it is broken whatever it claims, and saying so here is
      // the only evidence available.
      if (canBlameRealtime) _noteRealtimeMissedAClip();

      // Fetch/decrypt only when the ID changes. The receive path rechecks
      // ownership, sender and targets before touching the system clipboard.
      final previousId = _lastPolledItemId;
      final wasReady = _baselineReady;
      _lastPolledItemId = latestId;
      _baselineReady = true;
      // An account that had no clips at all: everything before the newest is
      // new too.
      final after = previousId ?? (wasReady ? '0' : null);
      if (after != null) {
        await _deliverSkippedClips(after: after, latest: latestId);
      }
      // Realtime delivered it while the id was being read.
      if (_claim(latestId)) {
        await _handleSmartAutoReceive(_receiveItem(latestId));
        // The fetch failed: wind the baseline back so the next poll - or the
        // next resume's catch-up - tries this row again instead of treating
        // it as seen.
        if (_failedFetchIds.remove(latestId) && _lastPolledItemId == latestId) {
          _lastPolledItemId = previousId;
        }
      }

      // Notify UI to refresh
      onClipboardReceived?.call();
    } on Exception catch (e) {
      debugPrint('[ClipboardSync] ❌ Polling error: $e');
    } finally {
      _isPolling = false;
      if (_pollRequested && !_isDisposed) {
        _pollRequested = false;
        unawaited(_pollForNewClipboards());
      }
    }
  }

  /// Clips that arrived between two polls, older than [latest] and newer than
  /// [after]. Only the newest is worth copying, but the integrations are
  /// meant to see every clip - as they do on the realtime path.
  Future<void> _deliverSkippedClips({
    required String after,
    required String latest,
  }) async {
    final afterId = int.tryParse(after);
    final latestId = int.tryParse(latest);
    if (afterId == null || latestId == null) return;
    try {
      // Below the full-history limit, so the repository does not prune its
      // media cache against this partial list.
      final recent = await _clipboardRepository.getHistory(limit: 10);
      final skipped = recent.where((item) {
        final id = int.tryParse(item.id);
        return id != null && id > afterId && id < latestId;
      }).toList()..sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));
      for (final item in skipped) {
        if (_isDisposed) return;
        if (_canReceive(item) && _claim(item.id)) _deliverReceived(item);
      }
    } on Exception catch (e) {
      debugPrint('[ClipboardSync] Could not deliver skipped clips: $e');
    }
  }

  bool _isDisposed = false;

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
  ///
  /// A clip detected as sensitive reaches neither. The integrations used to
  /// see only auto-sent text, which had already passed the auto-send path's
  /// check; the received and manual-send paths have no such check, so a
  /// password sent from the phone or pasted into the Spotlight was written to
  /// the vault in plaintext and POSTed to the webhook. The check fails closed.
  ///
  /// [screened] says the caller already ran this exact text through the
  /// check, as auto-send does before it sends, so it is not run twice.
  ///
  /// [isHtml] marks [content] as markup, delivered as its readable text -
  /// what the sending device's own plain-text flavour would have been.
  void _fireIntegrations({
    required String content,
    required String deviceType,
    required String direction,
    bool screened = false,
    bool isHtml = false,
  }) {
    final webhook = _webhookService;
    final obsidian = _obsidianService;
    if (_isDisposed || (webhook == null && obsidian == null)) return;

    unawaited(() async {
      try {
        final webhookOn =
            webhook != null && await _settingsService.getWebhookEnabled();
        final obsidianOn =
            obsidian != null && await _settingsService.getObsidianEnabled();
        // Nothing enabled means nothing to protect: skip the detection, which
        // for long clips runs in an isolate.
        if ((!webhookOn && !obsidianOn) || _isDisposed) return;

        // Converted only now, once something will use it: a web page's HTML
        // can run to megabytes, and the default is both integrations off.
        final text = isHtml ? htmlToPlainText(content) : content;
        if (text.isEmpty) return;

        if (!screened) {
          final detection = await _securityService.detectSensitiveDataAsync(
            text,
          );
          if (detection.isSensitive) {
            debugPrint(
              '[ClipboardSyncService] Integrations skipped: '
              '${detection.type?.label} detected',
            );
            return;
          }
          if (_isDisposed) return;
        }

        await Future.wait([
          if (webhookOn) _sendWebhook(webhook, text, deviceType, direction),
          if (obsidianOn) _appendToVault(obsidian, text, deviceType, direction),
        ]);
      } on Exception catch (e) {
        debugPrint('[ClipboardSyncService] Integrations skipped: $e');
      }
    }());
  }

  Future<void> _sendWebhook(
    IWebhookService webhook,
    String content,
    String deviceType,
    String direction,
  ) async {
    try {
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
  }

  Future<void> _appendToVault(
    IObsidianService obsidian,
    String content,
    String deviceType,
    String direction,
  ) async {
    try {
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

    // Integration deliveries still in flight are not awaited - dispose() is
    // sync - but each one checks _isDisposed before doing more work.

    // Unsubscribe from realtime
    _realtimeRetryTimer?.cancel();
    _realtimeRetryTimer = null;
    _dropRealtimeChannel();

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
