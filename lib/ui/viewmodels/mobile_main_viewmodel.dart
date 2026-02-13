import 'dart:async';
import 'dart:collection';
import 'dart:io';
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
    required IAuthService authService,
    required IClipboardRepository clipboardRepository,
    required IDeviceService deviceService,
    required ISecurityService securityService,
    required ISettingsService settingsService,
  }) : _authService = authService,
       _clipboardRepo = clipboardRepository,
       _deviceService = deviceService,
       _securityService = securityService,
       _settingsService = settingsService;

  final IAuthService _authService;
  final IClipboardRepository _clipboardRepo;
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
    await _initializeEncryption();
    await loadDevices();
    _historyLoading = true;
    notifyListeners();
    subscribeToRealtimeUpdates();
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
        _filteredHistoryItems = items;
        _historyLoading = false;
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
        notifyListeners();
      }
    }
  }

  /// Subscribe to realtime history updates
  void subscribeToRealtimeUpdates() {
    _historySubscription = _clipboardRepo.watchHistory().listen(
      (items) {
        if (_isDisposed) return;

        final oldFirstId = _historyItems.isNotEmpty
            ? _historyItems.first.id
            : null;

        _historyItems = items;
        _filterHistory(_historySearchQuery);
        _historyLoading = false;
        _cleanupCache();
        notifyListeners();

        // Auto-copy latest item if it's from another device
        if (items.isNotEmpty) {
          final latest = items.first;
          if (oldFirstId == null || latest.id != oldFirstId) {
            unawaited(_autoCopyToClipboard(latest));
          }
        }
      },
      onError: (Object error) {
        debugPrint('[MobileMainVM] Realtime subscription error: $error');
        if (!_isDisposed) {
          _historyLoading = false;
          _historyError = 'Failed to load history. Pull to refresh.';
          notifyListeners();
        }
      },
    );
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
      // Encrypt if enabled
      var finalContent = content;
      if (_encryptionService != null && await _encryptionService!.isEnabled()) {
        finalContent = await _encryptionService!.encrypt(content);
      }

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

      String mimeType;
      ContentType contentType;

      final path = image.path.toLowerCase();
      if (path.endsWith('.png')) {
        mimeType = 'image/png';
        contentType = ContentType.imagePng;
      } else if (path.endsWith('.jpg') || path.endsWith('.jpeg')) {
        mimeType = 'image/jpeg';
        contentType = ContentType.imageJpeg;
      } else if (path.endsWith('.gif')) {
        mimeType = 'image/gif';
        contentType = ContentType.imageGif;
      } else {
        mimeType = 'image/jpeg';
        contentType = ContentType.imageJpeg;
      }

      await _clipboardRepo.insertImage(
        userId: _authService.currentUserId ?? '',
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        deviceName: null,
        imageBytes: bytes,
        mimeType: mimeType,
        contentType: contentType,
      );

      if (!_isDisposed) {
        _isUploadingImage = false;
        notifyListeners();
        onSuccess?.call();
        unawaited(loadHistory());
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
      final result = await FilePicker.platform.pickFiles();
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

      final deviceType = ClipboardRepository.getCurrentDeviceType();
      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        bytes,
        file.name,
      );

      await _clipboardRepo.insertFile(
        userId: _authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        fileBytes: bytes,
        originalFilename: file.name,
        contentType: fileTypeInfo.contentType,
        mimeType: fileTypeInfo.mimeType,
      );

      if (!_isDisposed) {
        onSuccess?.call(file.name);
        unawaited(loadHistory());
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

        // ignore: deprecated_member_use
        await Share.shareXFiles([
          XFile(tempFile.path),
        ], text: 'Shared via GhostCopy');
      } else if (item.isRichText) {
        var finalContent = _decryptedContentCache[item.id] ?? item.content;

        if (_decryptedContentCache[item.id] == null &&
            _encryptionService != null &&
            item.isEncrypted) {
          try {
            finalContent = await _encryptionService!.decrypt(item.content);
            _cacheDecryptedContent(item.id, finalContent);
          } on Exception catch (e) {
            debugPrint(
              '[MobileMainVM] Decryption failed, using raw content: $e',
            );
            finalContent = item.content;
          }
        }

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          await clipboardService.writeText(finalContent);
        }

        onSuccess?.call('Copied ${item.richTextFormat?.value ?? "rich text"}');
      } else {
        var finalContent = _decryptedContentCache[item.id] ?? item.content;

        if (_decryptedContentCache[item.id] == null &&
            _encryptionService != null &&
            item.isEncrypted) {
          try {
            finalContent = await _encryptionService!.decrypt(item.content);
            _cacheDecryptedContent(item.id, finalContent);
          } on Exception catch (e) {
            debugPrint(
              '[MobileMainVM] Decryption failed, using raw content: $e',
            );
            finalContent = item.content;
          }
        }

        await clipboardService.writeText(finalContent);
        onSuccess?.call('Copied to clipboard');
      }
    } on Exception catch (e) {
      debugPrint('[MobileMainVM] Failed to copy: $e');
      onError?.call('Failed to copy: $e');
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

          // ignore: deprecated_member_use
          await Share.shareXFiles([
            XFile(tempFile.path),
          ], text: 'Shared via GhostCopy');
          debugPrint(
            '[MobileMainVM] Opened Share Sheet for ${item.contentType.value}',
          );
        } else {
          debugPrint('[MobileMainVM] Failed to download file for sharing');
          return false;
        }
      } else {
        final clipboardService = ClipboardService.instance;

        // Decrypt if needed before copying to clipboard
        var content = item.content;
        if (_encryptionService != null && item.isEncrypted) {
          content = await _encryptionService!.decrypt(content);
        }

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
  }

  /// Called on system memory pressure
  void onMemoryPressure() {
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
        var finalContent = item.content;
        if (_encryptionService != null && item.isEncrypted) {
          finalContent = await _encryptionService!.decrypt(item.content);
        }

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          await clipboardService.writeText(finalContent);
        }

        debugPrint(
          '[MobileMainVM] Auto-copied ${item.richTextFormat?.value ?? "rich text"} to clipboard',
        );
      } else {
        var finalContent = item.content;
        if (_encryptionService != null && item.isEncrypted) {
          finalContent = await _encryptionService!.decrypt(item.content);
        }

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
