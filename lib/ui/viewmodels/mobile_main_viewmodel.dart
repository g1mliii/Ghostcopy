import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' show Rect;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/clipboard_service.dart';
import '../../services/device_service.dart';
import '../../services/file_type_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/media_memory_cache.dart';
import '../../services/security_service.dart';
import '../../services/settings_service.dart';
import '../../services/transformer_service.dart';
import '../../services/widget_service.dart';

/// ViewModel for MobileMainScreen - handles business logic and state
///
/// Separates business logic from UI, making the code more testable and maintainable.
/// Uses ChangeNotifier for simple, built-in state management.
///
/// Responsibilities:
/// - Send state management (_isSending, _clipboardContent, etc.)
/// - Device state management (_devices, _selectedDeviceTypes)
/// - History state management (_historyItems, _filteredHistoryItems)
/// - Content caching (decrypted content, detection results)
/// - Timer management (clipboard clear, search debounce)
/// - Lifecycle hooks (onAppPaused, onAppResumed, onMemoryPressure)
///
/// UI responsibilities (remain in widget):
/// - TextEditingControllers (Flutter platform widgets)
/// - WidgetsBindingObserver (widget lifecycle)
/// - MethodChannel setup (delegates to ViewModel)
/// - Stream subscriptions for share intents / deep links
/// - Animations (_StaggeredHistoryItem)
class MobileMainViewModel extends ChangeNotifier {
  MobileMainViewModel({
    required this._authService,
    required IClipboardRepository clipboardRepository,
    required this._deviceService,
    required this._securityService,
    required this._settingsService,
  }) : _clipboardRepo = clipboardRepository;

  final IAuthService _authService;
  final IClipboardRepository _clipboardRepo;

  /// Encrypted clips in the last history load that the local passphrase could
  /// not open. They are excluded from [historyItems], so the UI shows a
  /// passphrase prompt rather than an empty-history message.
  ValueListenable<int> get undecryptableItemCount =>
      _clipboardRepo.undecryptableItemCount;
  final IDeviceService _deviceService;
  final ISecurityService _securityService;
  final ISettingsService _settingsService;

  // ========== SEND STATE ==========

  bool _isSending = false;
  bool get isSending => _isSending;

  bool _isUploadingImage = false;
  bool get isUploadingImage => _isUploadingImage;

  String? _sendErrorMessage;
  String? get sendErrorMessage => _sendErrorMessage;

  ClipboardContent? _clipboardContent;
  ClipboardContent? get clipboardContent => _clipboardContent;

  bool _lastSendWasFromPaste = false;

  // ========== DEVICE STATE ==========

  List<Device> _devices = [];
  List<Device> get devices => _devices;

  /// The user's devices collapsed to one entry per device TYPE.
  ///
  /// target_device_type is a device_type_enum[] - the backend can only route by
  /// platform, never to an individual machine. The chip row used to render one
  /// chip per device but toggle that device's TYPE, so with two Windows
  /// machines tapping "Work PC" lit up "Home PC" as well and delivered to both.
  /// The label promised something the schema cannot do.
  ///
  /// Grouping here keeps the selector honest while preserving what was good
  /// about it: when a type has exactly one device, that device's name IS an
  /// accurate label for the type, so it is still shown.
  List<DeviceTypeTarget> get deviceTypeTargets {
    final byType = <String, List<Device>>{};
    for (final device in _devices) {
      byType.putIfAbsent(device.deviceType, () => <Device>[]).add(device);
    }

    final targets = byType.entries
        .map((e) => DeviceTypeTarget(deviceType: e.key, devices: e.value))
        .toList()
      ..sort((a, b) => a.deviceType.compareTo(b.deviceType));
    return targets;
  }

  final Set<String> _selectedDeviceTypes = {};
  Set<String> get selectedDeviceTypes => _selectedDeviceTypes;

  bool _devicesLoading = false;
  bool get devicesLoading => _devicesLoading;

  String? _deviceError;
  String? get deviceError => _deviceError;

  // ========== HISTORY STATE ==========

  List<ClipboardItem> _historyItems = [];
  List<ClipboardItem> get historyItems => _historyItems;

  List<ClipboardItem> _filteredHistoryItems = [];
  List<ClipboardItem> get filteredHistoryItems => _filteredHistoryItems;

  bool _historyLoading = false;
  bool get historyLoading => _historyLoading;

  String? _historyError;
  String? get historyError => _historyError;

  String _historySearchQuery = '';
  String get historySearchQuery => _historySearchQuery;

  StreamSubscription<List<ClipboardItem>>? _historySubscription;
  Timer? _realtimeReconnectTimer;
  int _realtimeRetryCount = 0;

  // ========== CACHES ==========

  final Map<String, String> _decryptedContentCache = <String, String>{};
  Map<String, String> get decryptedContentCache =>
      UnmodifiableMapView(_decryptedContentCache);

  final Map<String, ContentDetectionResult> _detectionCache =
      <String, ContentDetectionResult>{};
  Map<String, ContentDetectionResult> get detectionCache =>
      UnmodifiableMapView(_detectionCache);

  static const int _maxCacheSize = 20;

  // ========== ENCRYPTION ==========

  EncryptionService? _encryptionService;
  EncryptionService? get encryptionService => _encryptionService;

  // ========== TIMERS ==========

  Timer? _clipboardClearTimer;
  Timer? _searchDebounceTimer;
  static const Duration _searchDebounceDelay = Duration(milliseconds: 200);

  // ========== DISPOSAL TRACKING ==========

  bool _isDisposed = false;

  // ========== INITIALIZATION ==========

  /// Initialize the ViewModel - call once after construction
  Future<void> initialize() async {
    _historyLoading = true;
    notifyListeners();
    subscribeToRealtimeUpdates();

    // Run all three concurrently. They were serialized - key derivation, then
    // the device list, then history - which put ~1s of device fetch on the
    // critical path for a list that does not need it, and made the clipboard
    // appear about four seconds after the screen did.
    //
    // Safe to overlap because EncryptionService.initialize() guards concurrent
    // callers with _initFuture, and the decrypt step inside loadHistory()
    // calls it again through _ensureEncryptionInitialized() - so the rows are
    // fetched over the network WHILE the key is being derived, and decryption
    // still waits for the same single derivation.
    //
    // Do not let first paint depend on the websocket either: the stream used
    // to be the ONLY source of the initial list, so a realtime failure left
    // the screen on a spinner even though a plain REST fetch would have
    // worked.
    await Future.wait([
      _initializeEncryption(),
      loadDevices(),
      loadHistory(),
    ]);
  }

  Future<void> _initializeEncryption() async {
    final userId = _authService.currentUserId;
    if (userId != null) {
      _encryptionService = EncryptionService.instance;
      await _encryptionService!.initialize(userId);
    }
  }

  // ========== PUBLIC METHODS ==========

  /// Toggle device type selection
  void toggleDeviceType(String deviceType) {
    final changed = _selectedDeviceTypes.contains(deviceType)
        ? _selectedDeviceTypes.remove(deviceType)
        : _selectedDeviceTypes.add(deviceType);
    if (changed) notifyListeners();
  }

  /// Clear device type selection (send to all)
  void clearDeviceTypeSelection() {
    _selectedDeviceTypes.clear();
    notifyListeners();
  }

  /// Set send error message
  void setSendError(String? error) {
    _sendErrorMessage = error;
    notifyListeners();
  }

  /// Clear send error
  void clearSendError() {
    _sendErrorMessage = null;
    notifyListeners();
  }

  /// Update clipboard content (set from widget when paste area changes)
  void updateClipboardContent(ClipboardContent? content) {
    _clipboardContent = content;
    notifyListeners();
  }

  /// Clear pending clipboard attachment (image/file) from paste area state.
  void clearPendingAttachment() {
    if (_clipboardContent == null && _sendErrorMessage == null) {
      return;
    }

    _clipboardContent = null;
    _sendErrorMessage = null;
    notifyListeners();
  }

  /// Populate from system clipboard
  /// Returns display text and updates _clipboardContent
  Future<(String displayText, ClipboardContent? content)?>
  populateFromClipboard() async {
    try {
      final clipboardService = ClipboardService.instance;
      final clipboardContent = await clipboardService.read();

      if (clipboardContent.isEmpty) {
        debugPrint('[MobileMainVM] Clipboard is empty');
        return null;
      }

      String displayText;
      if (clipboardContent.hasImage) {
        final mimeType = clipboardContent.mimeType ?? 'unknown';
        final sizeKB = (clipboardContent.imageBytes?.length ?? 0) / 1024;
        displayText =
            '[Image: ${mimeType.split('/').last} (${sizeKB.toStringAsFixed(1)}KB)]';
        debugPrint(
          '[MobileMainVM] Auto-pasted image: $mimeType, ${sizeKB.toStringAsFixed(1)}KB',
        );
      } else if (clipboardContent.hasHtml) {
        displayText = clipboardContent.html ?? '';
        debugPrint(
          '[MobileMainVM] Auto-pasted HTML: ${displayText.length} chars',
        );
      } else if (clipboardContent.hasFile) {
        displayText =
            '[File: ${clipboardContent.filename} (${clipboardContent.fileBytes?.length} bytes)]';
        debugPrint(
          '[MobileMainVM] Auto-pasted file: ${clipboardContent.filename}',
        );
      } else {
        displayText = clipboardContent.text ?? '';
        debugPrint(
          '[MobileMainVM] Auto-pasted text: ${displayText.length} chars',
        );
      }

      if (displayText.isNotEmpty) {
        _clipboardContent = clipboardContent;
        notifyListeners();
        return (displayText, clipboardContent);
      }

      return null;
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Could not read clipboard: $e');
      return null;
    }
  }

  /// Load devices
  Future<void> loadDevices({bool forceRefresh = false}) async {
    _devicesLoading = true;
    _deviceError = null;
    notifyListeners();

    try {
      final devices = await _deviceService.getUserDevices(
        forceRefresh: forceRefresh,
      );
      if (!_isDisposed) {
        _devices = devices;
        _devicesLoading = false;
        _deviceError = null;
        notifyListeners();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to load devices: $e');
      if (!_isDisposed) {
        _devicesLoading = false;
        _deviceError = 'Failed to load devices. Tap to retry.';
        notifyListeners();
      }
    }
  }

  /// Load history (one-shot fetch)
  Future<void> loadHistory() async {
    _historyLoading = true;
    notifyListeners();

    try {
      final items = await _clipboardRepo.getHistory();
      if (!_isDisposed) {
        _historyItems = items;
        _filterHistory(_historySearchQuery);
        _historyLoading = false;
        // A successful fetch is what "pull to refresh" promised, so the error
        // MUST be cleared here. It previously survived until sign-out, and
        // _buildHistoryList() returns the error pane before it ever looks at
        // the items - so one realtime hiccup hid the list permanently and
        // pulling to refresh appeared to do nothing at all.
        _historyError = null;
        _cleanupCache();
        notifyListeners();

        // Update widget with latest clipboard data (non-blocking)
        unawaited(
          WidgetService().updateWidgetData(items).catchError((Object e) {
            debugPrint('[MobileMainVM] Failed to update widget: $e');
          }),
        );
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to load history: $e');
      if (!_isDisposed) {
        _historyLoading = false;
        // Only claim failure when there is nothing on screen. Replacing a good
        // list with a full-page error because a refresh failed loses the
        // user's clips over a dropped connection.
        if (_historyItems.isEmpty) {
          _historyError = 'Failed to load history. Pull to refresh.';
        }
        notifyListeners();
      }
    }
  }

  /// Subscribe to realtime history updates
  void subscribeToRealtimeUpdates() {
    final Stream<List<ClipboardItem>> stream;
    try {
      // watchHistory() throws synchronously when there is no session, which
      // bypasses onError entirely and previously escaped initialize() as an
      // unhandled exception - leaving historyLoading stuck true forever.
      stream = _clipboardRepo.watchHistory();
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Could not open realtime stream: $e');
      _scheduleRealtimeReconnect();
      return;
    }

    _historySubscription = stream.listen(
      (items) {
        if (_isDisposed) return;

        // The stream is alive again; forget any previous backoff.
        _realtimeRetryCount = 0;
        _historyError = null;

        final oldFirstId = _historyItems.isNotEmpty
            ? _historyItems.first.id
            : null;

        _historyItems = items;
        _filterHistory(_historySearchQuery);
        _historyLoading = false;
        _cleanupCache();
        notifyListeners();

        // Auto-copy the latest item, but only when it genuinely came from
        // another device AND was targeted at this one. Previously this copied
        // any new row, so a clip sent to "Windows only" still overwrote the
        // phone's clipboard - the exact leak device targeting exists to stop.
        // Mirrors the desktop checks in ClipboardSyncService.
        if (items.isNotEmpty) {
          final latest = items.first;
          if (oldFirstId == null || latest.id != oldFirstId) {
            final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
            final isFromDifferentDevice =
                latest.deviceName == null ||
                currentDeviceName == null ||
                latest.deviceName != currentDeviceName;

            final targets = latest.targetDeviceTypes;
            final isTargetedToMe =
                targets == null ||
                targets.isEmpty ||
                targets.contains(ClipboardRepository.getCurrentDeviceType());

            if (isFromDifferentDevice && isTargetedToMe) {
              unawaited(_autoCopyToClipboard(latest));
            } else {
              debugPrint(
                '[MobileMainVM] Skipped auto-copy '
                '(fromOtherDevice=$isFromDifferentDevice, '
                'targeted=$isTargetedToMe)',
              );
            }
          }
        }
      },
      onError: (Object error) {
        debugPrint('[MobileMainVM] Realtime subscription error: $error');
        if (_isDisposed) return;

        _historyLoading = false;
        // Keep whatever is already on screen. Only a cold failure - nothing
        // loaded at all - justifies replacing the list with an error pane.
        if (_historyItems.isEmpty) {
          _historyError = 'Failed to load history. Pull to refresh.';
        }
        notifyListeners();

        // A stream error ends the subscription, and nothing re-armed it: one
        // dropped websocket meant new clips silently stopped arriving for the
        // rest of the session, with pull-to-refresh the only way to see
        // anything. Re-subscribe, and fall back to a one-shot fetch so the
        // list is correct even while realtime is still down.
        _scheduleRealtimeReconnect();
      },
    );
  }

  /// Re-arm the realtime subscription after an error, backing off so a server
  /// outage does not turn into a reconnect loop.
  void _scheduleRealtimeReconnect() {
    if (_isDisposed || _realtimeReconnectTimer?.isActive == true) return;

    final attempt = ++_realtimeRetryCount;
    // 2s, 4s, 8s, 16s, 30s, 30s...
    final seconds = attempt >= 5 ? 30 : 1 << attempt;
    debugPrint(
      '[MobileMainVM] Reconnecting realtime in ${seconds}s (attempt $attempt)',
    );

    _realtimeReconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (_isDisposed) return;
      await _historySubscription?.cancel();
      _historySubscription = null;
      subscribeToRealtimeUpdates();
      // Realtime only delivers changes from here on, so fetch the rows that
      // landed while the connection was down.
      await loadHistory();
    });
  }

  /// Filter history based on search query
  void filterHistory(String query) {
    _filterHistory(query);
    notifyListeners();
  }

  /// Debounced filter history
  void filterHistoryDebounced(String query) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounceDelay, () {
      if (!_isDisposed) {
        _filterHistory(query);
        notifyListeners();
      }
    });
  }

  /// Handle send action
  ///
  /// [pasteText] - current text from the paste controller
  /// [onSendSuccess] - callback for UI actions (clear text, show toast)
  /// Returns true if sensitive data warning should be shown
  Future<bool> checkSensitiveData(String content) async {
    final securityResult = await _securityService.detectSensitiveDataAsync(
      content,
    );
    return securityResult.isSensitive;
  }

  /// Execute the send operation
  ///
  /// [pasteText] - current text from the paste controller
  /// [onSendSuccess] - callback after successful send (clear paste area, show toast)
  Future<void> handleSend(
    String pasteText, {
    VoidCallback? onSendSuccess,
  }) async {
    // Check if sending image
    if (_clipboardContent?.hasImage ?? false) {
      await _sendImage(onSendSuccess: onSendSuccess);
      return;
    }

    // Staged file (picked or shared in). Goes through the same Send button as
    // everything else so device targeting applies.
    if (_clipboardContent?.hasFile ?? false) {
      await _sendFile(onSendSuccess: onSendSuccess);
      return;
    }

    final content = pasteText.trim();
    if (content.isEmpty) {
      _sendErrorMessage = 'Please paste or type content to send';
      notifyListeners();
      return;
    }

    _isSending = true;
    _sendErrorMessage = null;
    notifyListeners();

    try {
      // NOTE: do NOT encrypt here. ClipboardRepository.insert() encrypts
      // when encryption is enabled; doing it here as well stored E(E(content))
      // against is_encrypted=true, so readers decrypted once and got ciphertext.
      final finalContent = content;

      // Determine target devices
      List<String>? targetTypes;
      if (_selectedDeviceTypes.isNotEmpty) {
        targetTypes = _selectedDeviceTypes.toList();
      }

      final item = ClipboardItem(
        id: '',
        userId: _authService.currentUserId ?? '',
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        content: finalContent,
        targetDeviceTypes: targetTypes,
        createdAt: DateTime.now(),
      );

      await _clipboardRepo.insert(item);
      debugPrint('[MobileMainVM] Sent clipboard item');

      if (!_isDisposed) {
        _isSending = false;
        _clipboardContent = null;
        notifyListeners();

        onSendSuccess?.call();

        // Reload history (non-blocking)
        unawaited(loadHistory());

        // Security: Schedule clipboard auto-clear
        _lastSendWasFromPaste = true;
        await _scheduleClipboardClear();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to send: $e');
      if (!_isDisposed) {
        _isSending = false;
        _sendErrorMessage = 'Failed to send: $e';
        notifyListeners();
      }
    }
  }

  /// Send image from clipboard content
  /// Send a staged file, honouring the selected device chips.
  ///
  /// Mirrors _sendImage. Files previously uploaded straight from the picker,
  /// which bypassed this entirely and therefore always went to every device.
  Future<void> _sendFile({VoidCallback? onSendSuccess}) async {
    final content = _clipboardContent;
    if (content?.hasFile != true) return;

    _isSending = true;
    _sendErrorMessage = null;
    notifyListeners();

    try {
      final bytes = content!.fileBytes!;
      final filename = content.filename ?? 'file';
      final typeInfo = FileTypeService.instance.detectFromBytes(
        bytes,
        filename,
      );

      List<String>? targetTypes;
      if (_selectedDeviceTypes.isNotEmpty) {
        targetTypes = _selectedDeviceTypes.toList();
      }

      await _clipboardRepo.insertFile(
        userId: _authService.currentUserId!,
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        deviceName: null,
        fileBytes: bytes,
        originalFilename: filename,
        contentType: typeInfo.contentType,
        mimeType: typeInfo.mimeType,
        targetDeviceTypes: targetTypes,
      );

      debugPrint(
        '[MobileMainVM] Sent file $filename '
        '(${(bytes.length / 1024).toStringAsFixed(1)} KB)',
      );

      if (!_isDisposed) {
        _clipboardContent = null;
        _isSending = false;
        notifyListeners();
        onSendSuccess?.call();
        unawaited(loadHistory());
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to send file: $e');
      if (!_isDisposed) {
        _isSending = false;
        _sendErrorMessage = 'Failed to send file';
        notifyListeners();
      }
    }
  }

  Future<void> _sendImage({VoidCallback? onSendSuccess}) async {
    if (_clipboardContent?.hasImage != true) return;

    _isSending = true;
    _sendErrorMessage = null;
    notifyListeners();

    try {
      final imageBytes = _clipboardContent!.imageBytes!;
      final mimeType = _clipboardContent!.mimeType!;

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
          _isSending = false;
          _sendErrorMessage = 'Unsupported image type: $mimeType';
          notifyListeners();
          return;
      }

      List<String>? targetTypes;
      if (_selectedDeviceTypes.isNotEmpty) {
        targetTypes = _selectedDeviceTypes.toList();
      }

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      await _clipboardRepo.insertImage(
        userId: _authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: targetTypes,
      );

      debugPrint(
        '[MobileMainVM] Sent image (${(imageBytes.length / 1024).toStringAsFixed(1)} KB)',
      );

      if (!_isDisposed) {
        _clipboardContent = null;
        _isSending = false;
        notifyListeners();

        onSendSuccess?.call();

        // Reload history (non-blocking)
        unawaited(loadHistory());

        _lastSendWasFromPaste = true;
        await _scheduleClipboardClear();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to send image: $e');
      if (!_isDisposed) {
        _isSending = false;
        _sendErrorMessage = 'Failed to send image: $e';
        notifyListeners();
      }
    }
  }

  /// Handle image upload from gallery
  ///
  /// [onSuccess] - callback for UI toast
  /// [onError] - callback for UI error toast
  Future<void> handleImageUpload({
    VoidCallback? onSuccess,
    void Function(String message)? onError,
  }) async {
    if (_isUploadingImage) return;

    _isUploadingImage = true;
    notifyListeners();

    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
      );

      if (image == null) {
        _isUploadingImage = false;
        notifyListeners();
        return;
      }

      final bytes = await image.readAsBytes();

      // Only the mime type is needed now: _sendImage derives ContentType from
      // it at send time.
      String mimeType;

      final path = image.path.toLowerCase();
      if (path.endsWith('.png')) {
        mimeType = 'image/png';
      } else if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
        mimeType = 'image/jpeg';
      } else if (path.endsWith('.gif')) {
        mimeType = 'image/gif';
      } else {
        mimeType = 'image/jpeg';
      }

      // STAGE, don't send. Picking an image now behaves like pasting one:
      // it appears in the preview and the user presses Send. Sending straight
      // from the picker skipped the device chips entirely, so every picked
      // image went to all devices regardless of what was selected.
      if (!_isDisposed) {
        _clipboardContent = ClipboardContent.image(bytes, mimeType);
        _isUploadingImage = false;
        notifyListeners();
        onSuccess?.call();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to upload image: $e');
      if (!_isDisposed) {
        _isUploadingImage = false;
        notifyListeners();
        onError?.call('Failed to upload image: $e');
      }
    }
  }

  /// Handle file pick and upload
  ///
  /// [onLargeFileConfirm] - callback for large file confirmation dialog, returns true to continue
  /// [onSuccess] - callback for UI toast
  /// [onError] - callback for UI error toast
  Future<void> handleFilePick({
    Future<bool> Function(String sizeMB)? onLargeFileConfirm,
    void Function(String filename)? onSuccess,
    void Function(String message)? onError,
  }) async {
    try {
      final result = await FilePicker.pickFiles();
      if (result == null) return;

      final file = result.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();

      // Validate file size (10MB limit)
      if (bytes.length > 10485760) {
        onError?.call('File too large: ${file.name} (max 10MB)');
        return;
      }

      // Warn for large files (>5MB)
      if (bytes.length > 5242880) {
        final sizeMB = (bytes.length / 1048576).toStringAsFixed(1);
        final shouldContinue = await onLargeFileConfirm?.call(sizeMB) ?? true;
        if (!shouldContinue) return;
      }

      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        bytes,
        file.name,
      );

      // STAGE, don't send - same reasoning as images above. This path used to
      // upload immediately on pick, which both skipped the preview and ignored
      // the selected device chips.
      if (!_isDisposed) {
        _clipboardContent = ClipboardContent.file(
          bytes,
          file.name,
          fileTypeInfo.mimeType,
        );
        notifyListeners();
        onSuccess?.call(file.name);
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] File pick failed: $e');
      onError?.call('Failed to upload file');
    }
  }

  /// Handle history item tap (copy to clipboard or share)
  ///
  /// [onCopySuccess] - callback for UI toast on text/rich text copy
  /// [onShareSuccess] - not needed, share sheet handles UX
  Future<void> handleHistoryItemTap(
    ClipboardItem item, {
    void Function(String message)? onSuccess,
    void Function(String message)? onError,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final clipboardService = ClipboardService.instance;

      if (item.isImage || item.isFile) {
        final fileBytes = await _clipboardRepo.downloadFile(item);
        if (fileBytes == null) {
          throw Exception('Failed to download file');
        }

        final filename =
            item.metadata?.originalFilename ??
            (item.isImage
                ? 'image.${item.mimeType?.split("/").last ?? "png"}'
                : 'file');

        final tempFile = await ClipboardService.instance.writeTempFile(
          fileBytes,
          filename,
        );

        await _shareFile(tempFile.path, sharePositionOrigin);
      } else if (item.isRichText) {
        // Content is already plaintext: getHistory()/watchHistory() run
        // _decryptItems() before handing items over. isEncrypted is retained
        // as metadata (the widget uses it to suppress previews), so it must
        // NOT be used to trigger a second decrypt here.
        final finalContent = _decryptedContentCache[item.id] ?? item.content;

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          await clipboardService.writeText(finalContent);
        }

        onSuccess?.call('Copied ${item.richTextFormat?.value ?? "rich text"}');
      } else {
        // Content is already plaintext: getHistory()/watchHistory() run
        // _decryptItems() before handing items over. isEncrypted is retained
        // as metadata (the widget uses it to suppress previews), so it must
        // NOT be used to trigger a second decrypt here.
        final finalContent = _decryptedContentCache[item.id] ?? item.content;

        await clipboardService.writeText(finalContent);
        onSuccess?.call('Copied to clipboard');
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to copy: $e');
      onError?.call('Failed to copy: $e');
    }
  }

  /// Open the OS share sheet for a file on disk.
  ///
  /// [sharePositionOrigin] is required on iPad: UIActivityViewController is
  /// presented as a popover there and must be anchored to the widget that
  /// triggered it, or UIKit throws. It is ignored on iPhone and Android.
  Future<void> _shareFile(String path, Rect? sharePositionOrigin) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path)],
        text: 'Shared via GhostCopy',
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  /// Delete a clip everywhere.
  ///
  /// Mirrors the desktop path: the repository owns the cascade (row, RAM
  /// cache, disk cache, image cache), and the R2 object is removed by the
  /// cleanup_storage_on_clipboard_delete trigger. This is a sync-wide delete,
  /// not a local hide - the clip disappears from every signed-in device.
  Future<bool> handleHistoryItemDelete(
    ClipboardItem item, {
    void Function(String message)? onSuccess,
    void Function(String message)? onError,
  }) async {
    // Drop it from the list first so the row does not spring back while the
    // network call is in flight; realtime will confirm the same removal.
    final index = _historyItems.indexWhere((i) => i.id == item.id);
    if (index != -1) _historyItems.removeAt(index);
    _filterHistory(_historySearchQuery);
    _decryptedContentCache.remove(item.id);
    _detectionCache.remove(item.id);
    notifyListeners();

    try {
      await _clipboardRepo.delete(item.id);
      debugPrint('[MobileMainVM] Deleted history item ${item.id}');
      onSuccess?.call('Clip deleted');
      return true;
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to delete history item: $e');
      // Put it back where it was - the clip still exists on the server, so
      // leaving the list short would misrepresent what is synced.
      if (index != -1 && index <= _historyItems.length) {
        _historyItems.insert(index, item);
      } else {
        _historyItems.add(item);
      }
      _filterHistory(_historySearchQuery);
      notifyListeners();
      onError?.call('Could not delete: $e');
      return false;
    }
  }

  /// Handle refresh (pull-to-refresh)
  Future<void> handleRefresh() async {
    await Future.wait([loadDevices(forceRefresh: true), loadHistory()]);
  }

  /// Handle shared files from share intent
  Future<void> handleSharedFiles(
    List<dynamic> files, {
    void Function(String message)? onSuccess,
  }) async {
    for (final file in files) {
      try {
        // file is SharedMediaFile from receive_sharing_intent
        final path = (file as dynamic).path as String;
        if (path.isEmpty) continue;

        final bytes = await File(path).readAsBytes();
        final filename = path.split(Platform.pathSeparator).last;

        final fileTypeInfo = FileTypeService.instance.detectFromBytes(
          bytes,
          filename,
        );

        final deviceType = ClipboardRepository.getCurrentDeviceType();

        await _clipboardRepo.insertFile(
          userId: _authService.currentUserId!,
          deviceType: deviceType,
          deviceName: null,
          fileBytes: bytes,
          originalFilename: filename,
          contentType: fileTypeInfo.contentType,
          mimeType: fileTypeInfo.mimeType,
        );

        onSuccess?.call('Shared file uploaded: $filename');
      } on Exception catch (e) {
        debugPrint('Error handling shared file: $e');
      }
    }
    unawaited(loadHistory());
  }

  /// Save shared text content
  Future<void> saveSharedContent(
    String content,
    Set<String> selectedDeviceTypes, {
    void Function(String message)? onSuccess,
    void Function(String message)? onError,
  }) async {
    try {
      final item = ClipboardItem(
        id: '',
        userId: _authService.currentUserId ?? '',
        content: content,
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        targetDeviceTypes: selectedDeviceTypes.isEmpty
            ? null
            : selectedDeviceTypes.toList(),
        createdAt: DateTime.now(),
      );

      await _clipboardRepo.insert(item);

      final message = selectedDeviceTypes.isEmpty
          ? 'Shared to all devices'
          : 'Shared to ${selectedDeviceTypes.join(", ")}';
      onSuccess?.call(message);
      debugPrint('[ShareSheet] Content saved');
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared content: $e');
      onError?.call('Failed to share content');
    }
  }

  /// Save shared image
  Future<void> saveSharedImage(
    Uint8List imageBytes,
    String mimeType,
    Set<String> selectedDeviceTypes, {
    void Function(String message)? onSuccess,
    void Function(String message)? onError,
  }) async {
    try {
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
          onError?.call('Unsupported image type: $mimeType');
          return;
      }

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      await _clipboardRepo.insertImage(
        userId: _authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: selectedDeviceTypes.isEmpty
            ? null
            : selectedDeviceTypes.toList(),
      );

      final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);
      final message = selectedDeviceTypes.isEmpty
          ? 'Shared image ($sizeKB KB) to all devices'
          : 'Shared image ($sizeKB KB) to ${selectedDeviceTypes.join(", ")}';
      onSuccess?.call(message);
      debugPrint('[ShareSheet] Image saved: $sizeKB KB');
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared image: $e');
      onError?.call('Failed to share image');
    }
  }

  /// Save shared file
  Future<void> saveSharedFile(
    Uint8List fileBytes,
    String mimeType,
    String filename,
    Set<String> selectedDeviceTypes, {
    void Function(String message)? onSuccess,
    void Function(String message)? onError,
  }) async {
    try {
      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        fileBytes,
        filename,
      );

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      await _clipboardRepo.insertFile(
        userId: _authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        fileBytes: fileBytes,
        mimeType: mimeType,
        contentType: fileTypeInfo.contentType,
        originalFilename: filename,
        targetDeviceTypes: selectedDeviceTypes.isEmpty
            ? null
            : selectedDeviceTypes.toList(),
      );

      final sizeKB = (fileBytes.length / 1024).toStringAsFixed(1);
      final message = selectedDeviceTypes.isEmpty
          ? 'Shared $filename ($sizeKB KB) to all devices'
          : 'Shared $filename ($sizeKB KB) to ${selectedDeviceTypes.join(", ")}';
      onSuccess?.call(message);
      debugPrint('[ShareSheet] File saved: $filename ($sizeKB KB)');
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared file: $e');
      onError?.call('Failed to share file');
    }
  }

  /// Process share action from notification or deep link
  Future<bool> processShareAction(String clipboardId, {String? action}) async {
    try {
      final items = await _clipboardRepo.getHistory(limit: 100);

      ClipboardItem? item;
      for (final i in items) {
        if (i.id == clipboardId) {
          item = i;
          break;
        }
      }

      if (item == null) {
        debugPrint('[MobileMainVM] Clipboard item $clipboardId not found');
        return false;
      }

      if (item.isImage || item.isFile || action == 'share') {
        final fileBytes = await _clipboardRepo.downloadFile(item);
        if (fileBytes != null) {
          final filename =
              item.metadata?.originalFilename ??
              (item.isImage
                  ? 'image.${item.mimeType?.split("/").last ?? "png"}'
                  : 'file');

          final tempFile = await ClipboardService.instance.writeTempFile(
            fileBytes,
            filename,
          );

          // No anchor: this path is driven by an external share intent, so
          // there is no widget to point an iPad popover at.
          await _shareFile(tempFile.path, null);
          debugPrint(
            '[MobileMainVM] Opened Share Sheet for ${item.contentType.value}',
          );
        } else {
          debugPrint('[MobileMainVM] Failed to download file for sharing');
          return false;
        }
      } else {
        final clipboardService = ClipboardService.instance;

        // Content is already plaintext: getHistory()/watchHistory() run
        // _decryptItems() before handing items over. isEncrypted is retained
        // as metadata (the widget uses it to suppress previews), so it must
        // NOT be used to trigger a second decrypt here.
        final content = item.content;

        switch (item.contentType) {
          case ContentType.html:
            await clipboardService.writeHtml(content);
            debugPrint('[MobileMainVM] Copied HTML to clipboard');
          case ContentType.markdown:
            await clipboardService.writeText(content);
            debugPrint('[MobileMainVM] Copied Markdown to clipboard');
          default:
            await clipboardService.writeText(content);
            debugPrint('[MobileMainVM] Copied text to clipboard');
        }
      }

      return true;
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Error processing share action: $e');
      return false;
    }
  }

  /// Handle notification action from native code
  Future<bool> handleNotificationAction({
    required String? clipboardId,
    required String? action,
  }) async {
    if (clipboardId == null || clipboardId.isEmpty) {
      debugPrint('[MobileMainVM] Notification action: empty clipboardId');
      return false;
    }

    debugPrint(
      '[MobileMainVM] Notification action: $action for clipboard $clipboardId',
    );

    return processShareAction(clipboardId, action: action);
  }

  // ========== LIFECYCLE HOOKS ==========

  /// Called when app goes to background
  void onAppPaused() {
    debugPrint(
      '[MobileMainVM] App backgrounded - Pausing Realtime subscription',
    );
    _historySubscription?.pause();

    if (_lastSendWasFromPaste) {
      _clearClipboardNow();
    }

    // Clear sensitive decrypted data from memory when backgrounded
    _decryptedContentCache.clear();

    _clipboardContent = null;
    notifyListeners();
  }

  /// Called when app returns to foreground
  void onAppResumed() {
    debugPrint('[MobileMainVM] App resumed - Resuming Realtime subscription');
    _historySubscription?.resume();

    // Re-fetch, don't just resume. Push notifications deliberately carry no
    // clipboard content - the body literally says "Open GhostCopy to view it"
    // - so opening the app IS the sync step. Resuming the subscription only
    // restores the flow of future events; anything that arrived while the app
    // was backgrounded would never appear until a manual pull-to-refresh.
    unawaited(loadHistory());
  }

  /// Called on system memory pressure
  void onMemoryPressure() {
    // Downloaded media is the largest thing this app holds in RAM.
    MediaMemoryCache.instance.clear();
    debugPrint(
      '[MobileMainVM] System memory pressure detected - clearing caches',
    );

    _decryptedContentCache.clear();
    _detectionCache.clear();

    _clipboardContent = null;

    if (_historyItems.length > 10) {
      _historyItems = _historyItems.take(10).toList();
      _filteredHistoryItems = _filteredHistoryItems.take(10).toList();
      debugPrint(
        '[MobileMainVM] Trimmed history to 10 items due to memory pressure',
      );
    }

    notifyListeners();
  }

  /// Clear caches (e.g. after returning from settings with new encryption keys)
  void clearCaches() {
    _decryptedContentCache.clear();
    _detectionCache.clear();
  }

  /// Drop every trace of the signed-out account's data.
  ///
  /// [clearCaches] only empties the two derived caches; the history list,
  /// filtered view, search query and device targeting all survived a sign-out,
  /// so the previous user's clips stayed on screen until the next load
  /// replaced them - and stayed in memory regardless.
  void clearUserState() {
    _decryptedContentCache.clear();
    _detectionCache.clear();
    _historyItems = [];
    _filteredHistoryItems = [];
    _historySearchQuery = '';
    _selectedDeviceTypes.clear();
    _sendErrorMessage = null;
    _historyError = null;
    _clipboardContent = null;
    if (!_isDisposed) notifyListeners();
  }

  // ========== CACHE MANAGEMENT ==========

  /// Add item to decrypted content cache with LRU eviction
  void cacheDecryptedContent(String itemId, String content) {
    _cacheDecryptedContent(itemId, content);
  }

  /// Add item to detection cache with LRU eviction
  void cacheDetectionResult(String itemId, ContentDetectionResult result) {
    _cacheDetectionResult(itemId, result);
  }

  void _cacheDecryptedContent(String itemId, String content) {
    if (_decryptedContentCache.length >= _maxCacheSize) {
      final oldestKey = _decryptedContentCache.keys.first;
      _decryptedContentCache.remove(oldestKey);
    }
    _decryptedContentCache[itemId] = content;
  }

  void _cacheDetectionResult(String itemId, ContentDetectionResult result) {
    if (_detectionCache.length >= _maxCacheSize) {
      final oldestKey = _detectionCache.keys.first;
      _detectionCache.remove(oldestKey);
    }
    _detectionCache[itemId] = result;
  }

  // ========== PRIVATE METHODS ==========

  void _filterHistory(String query) {
    _historySearchQuery = query;
    if (query.trim().isEmpty) {
      _filteredHistoryItems = _historyItems;
    } else {
      final lowerQuery = query.toLowerCase();
      _filteredHistoryItems = _historyItems.where((item) {
        if (item.content.toLowerCase().contains(lowerQuery)) {
          return true;
        }
        if (item.deviceName != null &&
            item.deviceName!.toLowerCase().contains(lowerQuery)) {
          return true;
        }
        if (item.mimeType != null &&
            item.mimeType!.toLowerCase().contains(lowerQuery)) {
          return true;
        }
        return false;
      }).toList();
    }
  }

  void _cleanupCache() {
    final currentIds = _historyItems.map((item) => item.id).toSet();

    _decryptedContentCache.removeWhere((id, _) => !currentIds.contains(id));
    _detectionCache.removeWhere((id, _) => !currentIds.contains(id));

    if (_decryptedContentCache.length > _maxCacheSize) {
      final entriesToRemove = _decryptedContentCache.length - _maxCacheSize;
      final keysToRemove = _decryptedContentCache.keys
          .take(entriesToRemove)
          .toList();
      for (final key in keysToRemove) {
        _decryptedContentCache.remove(key);
        _detectionCache.remove(key);
      }
    }

    final currentUrls = _historyItems
        .where((item) => item.isImage && item.content.isNotEmpty)
        .map((item) => item.content)
        .toSet();

    debugPrint(
      '[MobileMainVM] Cache cleanup complete, ${currentUrls.length} images in history',
    );
  }

  Future<void> _autoCopyToClipboard(ClipboardItem item) async {
    try {
      final clipboardService = ClipboardService.instance;

      if (item.isImage) {
        final bytes = await _clipboardRepo.downloadFile(item);
        if (bytes == null) {
          throw Exception('Failed to download image');
        }

        await clipboardService.writeImage(bytes);
        debugPrint(
          '[MobileMainVM] Auto-copied image to clipboard (${bytes.length} bytes)',
        );
      } else if (item.isRichText) {
        // Content is already plaintext: getHistory()/watchHistory() run
        // _decryptItems() before handing items over. isEncrypted is retained
        // as metadata (the widget uses it to suppress previews), so it must
        // NOT be used to trigger a second decrypt here.
        final finalContent = item.content;

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          await clipboardService.writeText(finalContent);
        }

        debugPrint(
          '[MobileMainVM] Auto-copied ${item.richTextFormat?.value ?? "rich text"} to clipboard',
        );
      } else {
        // Content is already plaintext: getHistory()/watchHistory() run
        // _decryptItems() before handing items over. isEncrypted is retained
        // as metadata (the widget uses it to suppress previews), so it must
        // NOT be used to trigger a second decrypt here.
        final finalContent = item.content;

        await clipboardService.writeText(finalContent);
        debugPrint('[MobileMainVM] Auto-copied text to clipboard');
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to auto-copy: $e');
    }
  }

  Future<void> _scheduleClipboardClear() async {
    _clipboardClearTimer?.cancel();

    final clearSeconds = await _settingsService.getClipboardAutoClearSeconds();

    if (clearSeconds == 0) {
      debugPrint('[MobileMainVM] Clipboard auto-clear disabled');
      return;
    }

    debugPrint(
      '[MobileMainVM] Clipboard will be cleared in $clearSeconds seconds',
    );

    _clipboardClearTimer = Timer(
      Duration(seconds: clearSeconds),
      _clearClipboardNow,
    );
  }

  void _clearClipboardNow() {
    ClipboardService.instance.clear();
    _lastSendWasFromPaste = false;
    debugPrint('[MobileMainVM] System clipboard cleared for security');
  }

  // ========== DISPOSAL ==========

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    _historySubscription?.cancel();
    _historySubscription = null;
    _realtimeReconnectTimer?.cancel();
    _realtimeReconnectTimer = null;
    _clipboardClearTimer?.cancel();
    _clipboardClearTimer = null;
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = null;

    _decryptedContentCache.clear();
    _detectionCache.clear();

    _clipboardContent = null;

    debugPrint('[MobileMainVM] Disposed');
    super.dispose();
  }
}

/// One selectable send target: a device TYPE, plus the devices it covers.
///
/// Exists because the clipboard table's target_device_type column is an array
/// of platform enums. A chip maps to one of these, never to a single device.
@immutable
class DeviceTypeTarget {
  const DeviceTypeTarget({required this.deviceType, required this.devices});

  final String deviceType;
  final List<Device> devices;

  /// A label that is true for every device this chip reaches.
  ///
  /// With one device of this type its name is unambiguous, so it is used - a
  /// clip sent to "windows" really does go to exactly that machine. With more
  /// than one, naming any of them would be a lie, so the platform and a count
  /// are shown instead.
  String get label => devices.length == 1
      ? devices.single.displayName
      : '${_platformLabel(deviceType)} (${devices.length})';

  /// Names of every device this chip delivers to, for the tooltip.
  String get deviceNames => devices.map((d) => d.displayName).join(', ');

  static String _platformLabel(String deviceType) => switch (deviceType) {
    'windows' => 'Windows',
    'macos' => 'macOS',
    'linux' => 'Linux',
    'android' => 'Android',
    'ios' => 'iOS',
    _ => deviceType,
  };
}
