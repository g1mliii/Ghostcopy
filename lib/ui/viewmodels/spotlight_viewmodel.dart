import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/clipboard_item.dart';
import '../../models/exceptions.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/clipboard_service.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/file_type_service.dart';
import '../../services/notification_service.dart';
import '../../services/temp_file_service.dart';
import '../../services/transformer_service.dart';

/// ViewModel for SpotlightScreen - handles business logic and state
///
/// Separates business logic from UI, making the code more testable and maintainable.
/// Uses ChangeNotifier for simple, built-in state management.
///
/// Responsibilities:
/// - Send state management (_content, _isSending, _errorMessage, etc.)
/// - History state management (_historyItems, _isLoadingHistory)
/// - Content detection and transformation
/// - Rate limiting and debouncing
/// - Timer management
///
/// UI responsibilities (remain in widget):
/// - Animation controllers (need TickerProvider)
/// - Text controllers and focus nodes (Flutter platform widgets)
/// - Panel navigation state (pure UI concern)
/// - Pausable wrappers (widget lifecycle)
class SpotlightViewModel extends ChangeNotifier {
  SpotlightViewModel({
    required this._authService,
    required IClipboardRepository clipboardRepository,
    required IClipboardSyncService clipboardSyncService,
    required this._transformerService,
    required this._notificationService,
  }) : _clipboardRepo = clipboardRepository,
       _syncService = clipboardSyncService;

  final IAuthService _authService;
  final IClipboardRepository _clipboardRepo;
  final IClipboardSyncService _syncService;
  final ITransformerService _transformerService;
  final INotificationService _notificationService;

  // ========== SEND STATE ==========

  String _content = '';
  String get content => _content;

  ClipboardContent? _clipboardContent;
  ClipboardContent? get clipboardContent => _clipboardContent;

  final Set<String> _selectedPlatforms = {};
  Set<String> get selectedPlatforms => _selectedPlatforms;

  bool _isSending = false;
  bool get isSending => _isSending;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool _isDragOver = false;
  bool get isDragOver => _isDragOver;

  // Rate limiting for manual sends
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // String caching for expensive computations
  String? _cachedSendButtonTargetText;
  String? get cachedSendButtonTargetText => _cachedSendButtonTargetText;

  // File picker state
  bool _isFilePickerOpen = false;
  bool get isFilePickerOpen => _isFilePickerOpen;

  // ========== HISTORY STATE ==========

  List<ClipboardItem> _historyItems = [];
  List<ClipboardItem> get historyItems => _historyItems;

  bool _isLoadingHistory = false;
  bool get isLoadingHistory => _isLoadingHistory;

  // ========== CONTENT DETECTION STATE ==========

  ContentDetectionResult? _detectedContentType;
  ContentDetectionResult? get detectedContentType => _detectedContentType;

  TransformationResult? _transformationResult;
  TransformationResult? get transformationResult => _transformationResult;

  Future<TransformationResult>? _jwtTransformFuture;
  Future<TransformationResult>? get jwtTransformFuture => _jwtTransformFuture;

  // ========== TIMERS ==========

  Timer? _contentDetectionTimer;
  Timer? _historyReloadTimer;
  Timer? _errorClearTimer;
  StreamSubscription<AuthState>? _authStateSubscription;
  String? _historyUserId;
  int _accountRevision = 0;

  // ========== INITIALIZATION ==========

  /// Initialize the ViewModel
  /// Call this once after construction
  Future<void> initialize() async {
    _historyUserId = _authService.currentUserId;

    // The desktop spotlight stays mounted while the auth panel switches
    // accounts. Without listening here it loaded the anonymous account once,
    // then kept showing that empty list after sign-in until the user toggled
    // encryption (the settings callback happened to refresh history). Reload
    // the repository as soon as Supabase announces the new user instead.
    _authStateSubscription = _authService.authStateChanges.listen((state) {
      final userId = state.session?.user.id;
      if (userId == _historyUserId) return;

      _historyUserId = userId;
      _accountRevision++;
      _historyItems = <ClipboardItem>[];
      _isLoadingHistory = true;
      notifyListeners();
      unawaited(_loadHistory(revision: _accountRevision));
    });

    // Load initial history
    await _loadHistory(revision: _accountRevision);

    // Set up Realtime callback for history updates
    _syncService.onClipboardReceived = _debouncedLoadHistory;
  }

  // ========== PUBLIC METHODS ==========

  /// Update content from text input
  void updateContent(String newContent) {
    if (_content == newContent) return;
    _content = newContent;
    _debouncedDetectContentType();
  }

  /// Update clipboard content (for images, files, HTML)
  void updateClipboardContent(ClipboardContent? content) {
    _clipboardContent = content;
    notifyListeners();
  }

  /// Clear pending clipboard payload from paste/upload preview.
  ///
  /// If [clearText] is true, also clears the text payload and transformation state
  /// so the composer returns to an empty text-entry state.
  void clearClipboardPayload({bool clearText = false}) {
    final hasClipboardPayload = _clipboardContent != null;
    final hasTextPayload = _content.isNotEmpty;
    if (!hasClipboardPayload && (!clearText || !hasTextPayload)) {
      return;
    }

    _clipboardContent = null;

    if (clearText) {
      _content = '';
      _detectedContentType = null;
      _transformationResult = null;
      _jwtTransformFuture = null;
      _contentDetectionTimer?.cancel();
      _contentDetectionTimer = null;
    }

    notifyListeners();
  }

  /// Toggle platform selection
  void togglePlatform(String platform) {
    if (_selectedPlatforms.contains(platform)) {
      _selectedPlatforms.remove(platform);
    } else {
      _selectedPlatforms.add(platform);
    }
    _cachedSendButtonTargetText = null; // Invalidate cache
    notifyListeners();
  }

  /// Clear platform selection (send to all devices)
  void clearPlatformSelection() {
    _selectedPlatforms.clear();
    _cachedSendButtonTargetText = null;
    notifyListeners();
  }

  /// Set drag over state
  void setDragOver({required bool isDragOver}) {
    if (_isDragOver == isDragOver) return;
    _isDragOver = isDragOver;
    notifyListeners();
  }

  /// Set file picker open state
  void setFilePickerOpen({required bool isOpen}) {
    if (_isFilePickerOpen == isOpen) return;
    _isFilePickerOpen = isOpen;
    notifyListeners();
  }

  /// Clear error message
  void clearError() {
    _errorMessage = null;
    _errorClearTimer?.cancel();
    _errorClearTimer = null;
    notifyListeners();
  }

  /// Refresh history manually
  Future<void> refreshHistory() async {
    await _loadHistory(revision: _accountRevision);
  }

  /// Populate content from system clipboard
  /// Returns ClipboardContent if there's something to paste
  Future<ClipboardContent?> populateFromClipboard() async {
    try {
      final clipboardService = ClipboardService.instance;
      final content = await clipboardService.read();

      if (content.hasImage) {
        _clipboardContent = content;
        _content = ''; // Clear text when image is pasted
        notifyListeners();
        debugPrint('[SpotlightVM] Populated image from clipboard');
        return content;
      } else if (content.hasFile) {
        _clipboardContent = content;
        _content = ''; // Clear text when file is pasted
        notifyListeners();
        debugPrint(
          '[SpotlightVM] Populated file from clipboard: ${content.filename}',
        );
        return content;
      } else if (content.hasHtml) {
        _clipboardContent = content;
        _content = content.text ?? ''; // Show plaintext preview
        notifyListeners();
        debugPrint('[SpotlightVM] Populated HTML from clipboard');
        return content;
      } else if (content.hasText) {
        _clipboardContent = null; // Clear rich content
        final text = content.text!;
        _content = text;
        _debouncedDetectContentType();
        notifyListeners();
        debugPrint('[SpotlightVM] Populated text from clipboard');
        return content;
      }

      return null;
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Failed to read clipboard: $e');
      return null;
    }
  }

  /// Handle send action - sends clipboard to Supabase
  ///
  /// UI callbacks:
  /// - onSendSuccess: Called after successful send (for clearing text controller and hiding window)
  /// - onSendError: Called on error (optional, error state is already set in ViewModel)
  Future<void> handleSend({VoidCallback? onSendSuccess}) async {
    final hasTextPayload = _content.trim().isNotEmpty;
    final hasClipboardPayload =
        (_clipboardContent?.hasFile ?? false) ||
        (_clipboardContent?.hasImage ?? false) ||
        (_clipboardContent?.hasHtml ?? false);

    if ((!hasTextPayload && !hasClipboardPayload) || _isSending) return;

    // Rate limit: prevent rapid repeated sends
    final now = DateTime.now();
    if (_lastSendTime != null &&
        now.difference(_lastSendTime!) < _minSendInterval) {
      debugPrint(
        'Send suppressed: rate limit (${now.difference(_lastSendTime!)})',
      );
      return;
    }

    _isSending = true;
    notifyListeners();

    try {
      // mark last send time early to avoid races
      _lastSendTime = now;

      // Get current user ID
      final userId = _authService.currentUserId;
      if (userId == null) {
        throw Exception('Not authenticated');
      }

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
      final targetDevicesList = _selectedPlatforms.isEmpty
          ? null
          : _selectedPlatforms.toList();

      // Insert into Supabase based on content type
      if (_clipboardContent?.hasFile ?? false) {
        // File content - upload to storage
        final bytes = _clipboardContent!.fileBytes!;
        final filename = _clipboardContent!.filename;

        // Detect file type
        final fileTypeInfo = FileTypeService.instance.detectFromBytes(
          bytes,
          filename,
        );

        await _clipboardRepo.insertFile(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          fileBytes: bytes,
          mimeType: fileTypeInfo.mimeType,
          contentType: fileTypeInfo.contentType,
          originalFilename: filename,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint(
          '[SpotlightVM] ↑ Sent file: $filename (${bytes.length} bytes)',
        );
      } else if (_clipboardContent?.hasImage ?? false) {
        // Image content - upload to storage
        final bytes = _clipboardContent!.imageBytes!;
        final mimeType = _clipboardContent!.mimeType ?? 'image/png';
        // Unknown image MIMEs used to fall through to GIF here, which sent a
        // PNG labelled as a GIF rather than failing.
        final contentType = ContentType.fromMimeType(mimeType);
        if (contentType == null || !contentType.isImage) {
          _isSending = false;
          _setError('Unsupported image type: $mimeType');
          return;
        }

        await _clipboardRepo.insertImage(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          imageBytes: bytes,
          mimeType: mimeType,
          contentType: contentType,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint('[SpotlightVM] ↑ Sent image: ${bytes.length} bytes');
      } else if (_clipboardContent?.hasHtml ?? false) {
        // HTML content
        await _clipboardRepo.insertRichText(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          content: _clipboardContent!.html!,
          format: RichTextFormat.html,
          targetDeviceTypes: targetDevicesList,
        );
        debugPrint('[SpotlightVM] ↑ Sent HTML: ${_content.length} chars');
      } else {
        // Plain text content
        final item = ClipboardItem(
          id: '0', // Will be generated by Supabase
          userId: userId,
          content: _content,
          deviceName: currentDeviceName,
          deviceType: currentDeviceType,
          targetDeviceTypes: targetDevicesList,
          createdAt: DateTime.now(),
        );
        await _clipboardRepo.insert(item);
        debugPrint('[SpotlightVM] ↑ Sent text: ${_content.length} chars');
      }

      final targetText = _selectedPlatforms.isEmpty
          ? 'all devices'
          : _selectedPlatforms.length == 1
          ? _selectedPlatforms.first.toLowerCase()
          : '${_selectedPlatforms.length} device types';

      debugPrint('Sent clipboard to $targetText');

      // Notify ClipboardSyncService to prevent duplicate auto-send
      _syncService.notifyManualSend(
        _content,
        clipboardContent: _clipboardContent,
      );

      // Show success toast
      _notificationService.showToast(
        message: 'Sent to $targetText',
        type: NotificationType.success,
      );

      // Clear content after successful send
      _content = '';
      _clipboardContent = null;
      _isSending = false;
      notifyListeners();

      // Call success callback for UI actions (clear text controller, hide window)
      onSendSuccess?.call();
    } on ValidationException catch (e) {
      _isSending = false;
      _setError('Validation error: ${e.message}');
    } on SecurityException catch (e) {
      _isSending = false;
      _setError('Security error: ${e.message}');
    } on Exception catch (e) {
      _isSending = false;
      _setError('Failed to send: $e');
    }
  }

  /// Set file content after file picker completes
  /// The widget handles FilePicker UI (dialogs, validation)
  /// This just stores the result
  void setFileContent(ClipboardContent content, String displayText) {
    _clipboardContent = content;
    _content = displayText;
    notifyListeners();
    debugPrint(
      '[SpotlightVM] File loaded: ${content.filename} (${content.fileBytes?.length ?? 0} bytes)',
    );
  }

  /// Handle copying a history item to clipboard
  ///
  /// UI callback:
  /// - onCopySuccess: Called after copy (to close history panel)
  Future<void> handleHistoryItemCopy(
    ClipboardItem item, {
    VoidCallback? onCopySuccess,
  }) async {
    try {
      final clipboardService = ClipboardService.instance;

      if (item.isImage) {
        // Download image and copy to clipboard
        final bytes = await _clipboardRepo.downloadFile(item);
        if (bytes != null) {
          await clipboardService.writeImage(bytes);
          debugPrint('[SpotlightVM] Copied image to clipboard');
        }
      } else if (item.isFile) {
        // Download file to temp location and copy path
        final bytes = await _clipboardRepo.downloadFile(item);
        if (bytes != null) {
          // Sniffed extension rather than a bare 'file': this path is written
          // to the clipboard, and a name with nothing after the dot gives the
          // receiving app no way to tell what it just pasted.
          // Shared with the mobile share paths. This copy never grew the
          // `image.*` case they have, which is the drift that comes of writing
          // the same naming rule out four times.
          final filename = FileTypeService.instance
              .resolveFilename(
                bytes,
                originalFilename: item.metadata?.originalFilename,
                isImage: item.isImage,
              )
              .name;
          final tempFile = await TempFileService.instance.saveTempFile(
            bytes,
            filename,
          );
          final tempPath = tempFile.path;

          await clipboardService.writeFilePath(tempPath);
          debugPrint('[SpotlightVM] Copied file path to clipboard: $tempPath');

          // Periodic cleanup retains the file while its URI is on the clipboard.
        }
      } else if (item.isRichText) {
        // Copy rich text with format
        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(item.content);
        } else {
          await clipboardService.writeText(item.content);
        }
        debugPrint('[SpotlightVM] Copied rich text to clipboard');
      } else {
        // Copy plain text
        await clipboardService.writeText(item.content);
        debugPrint('[SpotlightVM] Copied text to clipboard');
      }

      _notificationService.showToast(
        message: 'Copied to clipboard',
        type: NotificationType.success,
      );

      onCopySuccess?.call();
    } on Exception catch (e) {
      _setError('Failed to copy: $e');
      debugPrint('[SpotlightVM] Failed to copy history item: $e');
    }
  }

  /// Handle deleting a history item
  Future<void> handleHistoryItemDelete(ClipboardItem item) async {
    try {
      await _clipboardRepo.delete(item.id);
      _historyItems.removeWhere((i) => i.id == item.id);
      notifyListeners();
      debugPrint('[SpotlightVM] Deleted history item ${item.id}');

      _notificationService.showToast(message: 'Item deleted');
    } on Exception catch (e) {
      _setError('Failed to delete: $e');
      debugPrint('[SpotlightVM] Failed to delete history item: $e');
    }
  }

  // ========== PRIVATE METHODS ==========

  /// Load clipboard history from repository
  Future<void> _loadHistory({required int revision}) async {
    try {
      _isLoadingHistory = true;
      notifyListeners();

      final items = await _clipboardRepo.getHistory();
      if (_isDisposed || revision != _accountRevision) return;
      _historyItems = items;
      _isLoadingHistory = false;
      notifyListeners();

      debugPrint('[SpotlightVM] ✓ Loaded ${items.length} history items');
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Failed to load history: $e');
      if (_isDisposed || revision != _accountRevision) return;
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  /// Debounced history reload (called by Realtime updates)
  void _debouncedLoadHistory() {
    _historyReloadTimer?.cancel();
    _historyReloadTimer = Timer(
      const Duration(milliseconds: 500),
      () => _loadHistory(revision: _accountRevision),
    );
  }

  /// Debounced content type detection
  void _debouncedDetectContentType() {
    _contentDetectionTimer?.cancel();
    _contentDetectionTimer = Timer(
      const Duration(milliseconds: 300),
      _detectContentType,
    );
  }

  /// Detect content type for smart transformations
  Future<void> _detectContentType() async {
    if (_content.isEmpty) {
      _detectedContentType = null;
      _transformationResult = null;
      _jwtTransformFuture = null;
      notifyListeners();
      return;
    }

    final content = _content;
    try {
      final result = await _transformerService.detectContentType(content);
      if (_isDisposed || content != _content) return;
      final previous = _detectedContentType;
      _detectedContentType = result;

      // For JWT, prefetch transformation for instant display
      if (result.type == TransformerContentType.jwt) {
        _jwtTransformFuture = _transformerService.transform(
          content,
          TransformerContentType.jwt,
        );
      } else {
        _jwtTransformFuture = null;
      }

      // Plain text has no preview that changes with each edit. The field
      // already paints its own edits; avoid rebuilding the whole spotlight.
      if (previous?.type != result.type ||
          result.type != TransformerContentType.plainText) {
        notifyListeners();
      }
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Content detection failed: $e');
    }
  }

  /// Set error message with auto-clear timer
  void _setError(String message) {
    _errorMessage = message;
    notifyListeners();

    // Auto-clear error after 4 seconds
    _errorClearTimer?.cancel();
    _errorClearTimer = Timer(const Duration(seconds: 4), () {
      if (_errorMessage == message) {
        _errorMessage = null;
        notifyListeners();
      }
    });
  }

  // ========== DISPOSAL ==========

  bool _isDisposed = false;

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;

    // Cancel all timers
    _contentDetectionTimer?.cancel();
    _contentDetectionTimer = null;
    _historyReloadTimer?.cancel();
    _historyReloadTimer = null;
    _authStateSubscription?.cancel();
    _authStateSubscription = null;
    _errorClearTimer?.cancel();
    _errorClearTimer = null;

    // Clear Realtime callback
    _syncService.onClipboardReceived = null;

    // Clear cached futures
    _jwtTransformFuture = null;
    _transformationResult = null;

    // Clear large data to help GC
    _clipboardContent = null;
    _content = '';

    debugPrint('[SpotlightVM] Disposed');
    super.dispose();
  }
}
