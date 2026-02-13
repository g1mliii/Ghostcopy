import 'dart:async';

import 'package:flutter/foundation.dart';

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
    required IAuthService authService,
    required IClipboardRepository clipboardRepository,
    required IClipboardSyncService clipboardSyncService,
    required ITransformerService transformerService,
    required INotificationService notificationService,
  }) : _authService = authService,
       _clipboardRepo = clipboardRepository,
       _syncService = clipboardSyncService,
       _transformerService = transformerService,
       _notificationService = notificationService;

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

  // Track pending temp file cleanups
  final Set<String> _pendingTempFileCleanups = {};

  // Track temp file cleanup timers for cancellation on disposal
  final Set<Timer> _tempFileCleanupTimers = {};

  // ========== INITIALIZATION ==========

  /// Initialize the ViewModel
  /// Call this once after construction
  Future<void> initialize() async {
    // Load initial history
    await _loadHistory();

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
    await _loadHistory();
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
    if (_content.trim().isEmpty || _isSending) return;

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
        final contentType = mimeType.startsWith('image/png')
            ? ContentType.imagePng
            : mimeType.startsWith('image/jpeg')
            ? ContentType.imageJpeg
            : ContentType.imageGif;

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
        // Note: insertRichText doesn't support targetDeviceTypes yet
        await _clipboardRepo.insertRichText(
          userId: userId,
          deviceType: currentDeviceType,
          deviceName: currentDeviceName,
          content: _clipboardContent!.html!,
          format: RichTextFormat.html,
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
      _syncService.notifyManualSend(_content);

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
          final filename = item.metadata?.originalFilename ?? 'file';
          final tempFile = await TempFileService.instance.saveTempFile(
            bytes,
            filename,
          );
          final tempPath = tempFile.path;
          _pendingTempFileCleanups.add(tempPath);

          await clipboardService.writeFilePath(tempPath);
          debugPrint('[SpotlightVM] Copied file path to clipboard: $tempPath');

          // Schedule cleanup after 5 seconds - store timer for cancellation
          Timer? cleanupTimer;
          cleanupTimer = Timer(const Duration(seconds: 5), () {
            if (!_isDisposed) {
              TempFileService.instance.deleteTempFile(tempPath);
              _pendingTempFileCleanups.remove(tempPath);
            }
            if (cleanupTimer != null) {
              _tempFileCleanupTimers.remove(cleanupTimer);
            }
          });
          _tempFileCleanupTimers.add(cleanupTimer);
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
  Future<void> _loadHistory() async {
    try {
      _isLoadingHistory = true;
      notifyListeners();

      final items = await _clipboardRepo.getHistory();
      _historyItems = items;
      _isLoadingHistory = false;
      notifyListeners();

      debugPrint('[SpotlightVM] ✓ Loaded ${items.length} history items');
    } on Exception catch (e) {
      debugPrint('[SpotlightVM] Failed to load history: $e');
      _isLoadingHistory = false;
      notifyListeners();
    }
  }

  /// Debounced history reload (called by Realtime updates)
  void _debouncedLoadHistory() {
    _historyReloadTimer?.cancel();
    _historyReloadTimer = Timer(
      const Duration(milliseconds: 500),
      _loadHistory,
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

    try {
      final result = await _transformerService.detectContentType(_content);
      _detectedContentType = result;

      // For JWT, prefetch transformation for instant display
      if (result.type == TransformerContentType.jwt) {
        _jwtTransformFuture = _transformerService.transform(
          _content,
          TransformerContentType.jwt,
        );
      } else {
        _jwtTransformFuture = null;
      }

      notifyListeners();
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
    _errorClearTimer?.cancel();
    _errorClearTimer = null;

    // Cancel all temp file cleanup timers (CRITICAL: prevents memory leak)
    for (final timer in _tempFileCleanupTimers) {
      timer.cancel();
    }
    _tempFileCleanupTimers.clear();

    // Clear Realtime callback
    _syncService.onClipboardReceived = null;

    // Clear cached futures
    _jwtTransformFuture = null;
    _transformationResult = null;

    // Clear large data to help GC
    _clipboardContent = null;
    _content = '';

    // Clear temp file cleanup list
    _pendingTempFileCleanups.clear();

    debugPrint('[SpotlightVM] Disposed');
    super.dispose();
  }
}
