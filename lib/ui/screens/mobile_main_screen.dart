import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:share_plus/share_plus.dart';
import 'package:timeago/timeago.dart' as timeago;

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
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/cached_clipboard_image.dart';
import '../widgets/ghost_toast.dart';
import '../widgets/smart_action_buttons.dart';
import 'mobile_settings_screen.dart';

const _shareChannel = MethodChannel('com.ghostcopy.ghostcopy/share');
const _notificationChannel = MethodChannel(
  'com.ghostcopy.ghostcopy/notifications',
);

/// Mobile main screen with clipboard history and paste-to-send flow
///
/// Performance optimizations:
/// - RepaintBoundary around history items
/// - Cached device list
/// - Staggered animations with proper disposal
/// - const widgets where possible
/// - Decryption and content detection caching
/// - LRU cache cleanup (max 20 entries)
/// - Stable ValueKeys for list items
///
/// Features:
/// - Paste area with prominent CTA
/// - Device selector chips
/// - Send button with target selection
/// - History list (10 most recent items) with expand/collapse
/// - Pull-to-refresh
/// - Auto-copy on incoming items (temporary - will use FCM in production)
class MobileMainScreen extends StatefulWidget {
  const MobileMainScreen({
    required this.authService,
    required this.deviceService,
    required this.clipboardRepository,
    required this.securityService,
    required this.transformerService,
    required this.settingsService,
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final IClipboardRepository clipboardRepository;
  final ISecurityService securityService;
  final ITransformerService transformerService;
  final ISettingsService settingsService;

  @override
  State<MobileMainScreen> createState() => _MobileMainScreenState();
}

class _MobileMainScreenState extends State<MobileMainScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  // Paste area state
  final TextEditingController _pasteController = TextEditingController();
  bool _isSending = false;
  bool _isUploadingImage = false;
  String? _sendError;
  ClipboardContent?
  _clipboardContent; // Full clipboard content (images, HTML, text)

  // Device selection state
  List<Device> _devices = [];
  final Set<String> _selectedDeviceTypes = {};
  bool _devicesLoading = false;

  // History state
  List<ClipboardItem> _historyItems = [];
  List<ClipboardItem> _filteredHistoryItems = [];
  bool _historyLoading = false;
  StreamSubscription<List<ClipboardItem>>? _historySubscription;
  final TextEditingController _historySearchController =
      TextEditingController();
  String _historySearchQuery = '';

  // Share sheet state
  // (receive_sharing_intent package handles share intent routing)

  // Encryption service (lazy init)
  EncryptionService? _encryptionService;

  // Clipboard auto-clear timer (for security)
  Timer? _clipboardClearTimer;
  bool _lastSendWasFromPaste = false;

  // Search debouncing timer (performance optimization)
  Timer? _searchDebounceTimer;
  static const Duration _searchDebounceDelay = Duration(milliseconds: 200);

  // Performance optimization: Cache decrypted content and detection results
  // Key: item.id, Value: decrypted content
  final Map<String, String> _decryptedContentCache = {};
  // Key: item.id, Value: detection result
  final Map<String, ContentDetectionResult> _detectionCache = {};
  static const int _maxCacheSize =
      20; // Mobile: Small cache for 10 items + buffer

  @override
  void initState() {
    super.initState();
    // Register lifecycle observer to pause Realtime when app goes to background
    WidgetsBinding.instance.addObserver(this);

    _initializeEncryption();
    _loadDevices();

    // Set loading state, then subscribe to realtime stream
    // Stream provides initial snapshot, eliminating need for separate getHistory() call
    setState(() => _historyLoading = true);
    _subscribeToRealtimeUpdates();

    _initializeShareIntentListeners();
    _setupMethodChannels();
    _initDeepLinks();
  }

  StreamSubscription<Uri>? _linkSubscription;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pasteController.dispose();
    _historySearchController.dispose();
    _historySubscription?.cancel();
    _clipboardClearTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _intentDataStreamSubscription?.cancel();
    _linkSubscription?.cancel();

    // Remove method channel handlers to prevent memory leaks
    _shareChannel.setMethodCallHandler(null);
    _notificationChannel.setMethodCallHandler(null);

    // Clear caches
    _decryptedContentCache.clear();
    _detectionCache.clear();

    super.dispose();
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();

    // Handle initial link
    try {
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null) {
        unawaited(_handleDeepLink(initialUri));
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] ❌ Error getting initial link: $e');
    }

    // Handle coming links
    _linkSubscription = appLinks.uriLinkStream.listen(
      _handleDeepLink,
      onError: (Object err) {
        debugPrint('[MobileMain] ❌ Link stream error: $err');
      },
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    debugPrint('[MobileMain] 🔗 Deep link received: $uri');
    // Format: ghostcopy://share/{clipboardId}
    if (uri.scheme == 'ghostcopy' && uri.host == 'share') {
      final clipboardId = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : null;
      if (clipboardId != null) {
        await _processShareAction(clipboardId, action: 'share');
      }
    }
  }

  /// Handle app lifecycle changes: pause Realtime when backgrounding, resume when returning
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // App going to background: pause Realtime to conserve connection quota
      debugPrint(
        '[MobileMain] App backgrounded → Pausing Realtime subscription',
      );
      _historySubscription?.pause();

      // Security: Clear clipboard if user recently pasted and sent content
      if (_lastSendWasFromPaste) {
        _clearClipboardNow();
      }

      // Memory: Clear clipboard content to prevent memory leak (especially for large images)
      if (mounted) {
        setState(() {
          _clipboardContent = null;
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      // App coming to foreground: resume Realtime
      debugPrint('[MobileMain] App resumed → Resuming Realtime subscription');
      _historySubscription?.resume();

      // Auto-paste from clipboard (user-friendly - populates paste area automatically)
      _populateFromClipboard();
    }
  }

  /// Handle system memory pressure warnings (iOS/Android low-memory events)
  /// Aggressively clear caches to prevent app termination by OS
  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    debugPrint('[MobileMain] ⚠️  System memory pressure detected - clearing caches');
    
    // Clear content caches
    _decryptedContentCache.clear();
    _detectionCache.clear();
    
    // Clear Flutter image caches
    imageCache
      ..clear()
      ..clearLiveImages();
    
    // Clear clipboard content from memory (especially large images)
    if (mounted) {
      setState(() {
        _clipboardContent = null;
      });
    }
    
    // Trim history to most recent 10 items to reduce memory footprint
    if (mounted && _historyItems.length > 10) {
      setState(() {
        _historyItems = _historyItems.take(10).toList();
        _filteredHistoryItems = _filteredHistoryItems.take(10).toList();
      });
      debugPrint('[MobileMain] Trimmed history to 10 items due to memory pressure');
    }
  }

  Future<void> _initializeEncryption() async {
    final userId = widget.authService.currentUserId;
    if (userId != null) {
      // Use shared singleton instance
      _encryptionService = EncryptionService.instance;
      await _encryptionService!.initialize(userId);
    }
  }

  /// Auto-paste from system clipboard when app opens/resumes
  /// Populates paste area with text or shows image preview
  Future<void> _populateFromClipboard() async {
    try {
      final clipboardService = ClipboardService.instance;
      final clipboardContent = await clipboardService.read();

      if (clipboardContent.isEmpty) {
        debugPrint('[MobileMain] Clipboard is empty');
        return;
      }

      String displayText;
      if (clipboardContent.hasImage) {
        // For images, show indicator text in TextField
        final mimeType = clipboardContent.mimeType ?? 'unknown';
        final sizeKB = (clipboardContent.imageBytes?.length ?? 0) / 1024;
        displayText =
            '[Image: ${mimeType.split('/').last} (${sizeKB.toStringAsFixed(1)}KB)]';
        debugPrint(
          '[MobileMain] ↓ Auto-pasted image: $mimeType, ${sizeKB.toStringAsFixed(1)}KB',
        );
      } else if (clipboardContent.hasHtml) {
        // For HTML, show the HTML source
        displayText = clipboardContent.html ?? '';
        debugPrint(
          '[MobileMain] ↓ Auto-pasted HTML: ${displayText.length} chars',
        );
      } else if (clipboardContent.hasFile) {
        // For Files
        displayText =
            '[File: ${clipboardContent.filename} (${clipboardContent.fileBytes?.length} bytes)]';
        debugPrint(
          '[MobileMain] ↓ Auto-pasted file: ${clipboardContent.filename}',
        );
      } else {
        // For plain text
        displayText = clipboardContent.text ?? '';
        debugPrint(
          '[MobileMain] ↓ Auto-pasted text: ${displayText.length} chars',
        );
      }

      if (displayText.isNotEmpty && mounted) {
        setState(() {
          _clipboardContent = clipboardContent; // Store full clipboard content
          _pasteController.text = displayText;
          // Position cursor at end
          _pasteController.selection = TextSelection.fromPosition(
            TextPosition(offset: displayText.length),
          );
        });

        // Precache image to avoid re-decoding on rebuilds
        if (clipboardContent.hasImage && mounted) {
          unawaited(
            precacheImage(MemoryImage(clipboardContent.imageBytes!), context),
          );
        }
      }
    } on Exception catch (e) {
      // Silently fail if clipboard access denied (user may have sensitive content)
      debugPrint('[MobileMain] ⚠️ Could not read clipboard: $e');
    }
  }

  void _setupMethodChannels() {
    // Share intent handler
    _shareChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'handleShareIntent':
          // ignore: avoid_dynamic_calls
          final content = call.arguments['content'] as String?;
          if (content != null && content.isNotEmpty) {
            // Show device selector dialog
            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              content,
            );

            if (selectedDeviceTypes != null) {
              // Save in background (don't await)
              unawaited(_saveSharedContent(content, selectedDeviceTypes));
            }
            return true;
          }
          return false;

        case 'handleShareImage':
          // ignore: avoid_dynamic_calls
          final imageBytes = call.arguments['imageBytes'] as Uint8List?;
          // ignore: avoid_dynamic_calls
          final mimeType = call.arguments['mimeType'] as String?;

          if (imageBytes != null && imageBytes.isNotEmpty) {
            // Validate size (10MB limit - defense in depth)
            if (imageBytes.length > 10 * 1024 * 1024) {
              debugPrint(
                '[MobileMain] ❌ Image too large: ${imageBytes.length} bytes',
              );
              showGhostToast(
                context,
                'Image too large (max 10MB)',
                icon: Icons.error_outline,
                type: GhostToastType.error,
              );
              return false;
            }

            final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);

            // Show device selector
            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              'Image ($sizeKB KB)',
            );

            if (selectedDeviceTypes != null) {
              // Save in background (don't await)
              unawaited(
                _saveSharedImage(imageBytes, mimeType!, selectedDeviceTypes),
              );
            }
            return true;
          }
          return false;

        case 'handleShareFile':
          // ignore: avoid_dynamic_calls
          final fileBytes = call.arguments['fileBytes'] as Uint8List?;
          // ignore: avoid_dynamic_calls
          final mimeType = call.arguments['mimeType'] as String?;
          // ignore: avoid_dynamic_calls
          final filename = call.arguments['filename'] as String?;

          if (fileBytes != null && fileBytes.isNotEmpty && filename != null) {
            // Validate size (10MB limit - defense in depth)
            if (fileBytes.length > 10 * 1024 * 1024) {
              debugPrint(
                '[MobileMain] ❌ File too large: ${fileBytes.length} bytes',
              );
              showGhostToast(
                context,
                'File too large (max 10MB)',
                icon: Icons.error_outline,
                type: GhostToastType.error,
              );
              return false;
            }

            final sizeKB = (fileBytes.length / 1024).toStringAsFixed(1);

            // Show device selector
            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              '$filename ($sizeKB KB)',
            );

            if (selectedDeviceTypes != null) {
              // Save in background (don't await)
              unawaited(
                _saveSharedFile(fileBytes, mimeType!, filename, selectedDeviceTypes),
              );
            }
            return true;
          }
          return false;

        default:
          return false;
      }
    });

    // Notification action handler (for FCM notification taps)
    // Handles both iOS (from AppDelegate) and Android (from CopyActivity/MainActivity)
    // Memory leak prevention: Handler is removed in dispose()
    _notificationChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'handleNotificationAction':
          return _handleNotificationAction(call);

        default:
          return false;
      }
    });
  }

  /// Handle notification action from native code (iOS/Android)
  ///
  /// Called when:
  /// - iOS: User taps notification action button or copy button
  /// - Android: CopyActivity/MainActivity needs to fetch large content from DB
  ///
  /// Memory safety: No hanging references, all await calls properly handled
  Future<bool> _handleNotificationAction(MethodCall call) async {
    try {
      // ignore: avoid_dynamic_calls
      final clipboardId = call.arguments['clipboardId'] as String?;
      // ignore: avoid_dynamic_calls
      final action = call.arguments['action'] as String?;

      if (clipboardId == null || clipboardId.isEmpty) {
        debugPrint('[MobileMain] ⚠️ Notification action: empty clipboardId');
        return false;
      }

      debugPrint(
        '[MobileMain] 📬 Notification action: $action for clipboard $clipboardId',
      );

      return await _processShareAction(clipboardId, action: action);
    } on Exception catch (e) {
      debugPrint('[MobileMain] ❌ Error handling notification action: $e');
      return false;
    }
  }

  /// Process share action (from notification or deep link)
  ///
  /// Fetches the item by ID and either:
  /// - Downloads and opens Share Sheet (for files/images or explicit share action)
  /// - Copies content to clipboard (for text)
  Future<bool> _processShareAction(String clipboardId, {String? action}) async {
    try {
      // Fetch full clipboard item from database
      final items = await widget.clipboardRepository.getHistory(limit: 100);

      // Find the item with matching ID
      ClipboardItem? item;
      for (final i in items) {
        if (i.id == clipboardId) {
          item = i;
          break;
        }
      }

      if (item == null) {
        debugPrint('[MobileMain] ❌ Clipboard item $clipboardId not found');
        return false;
      }

      // Unified handling for Files and Images (Download & Share)
      // OR if action is explicitly 'share'
      if (item.isImage || item.isFile || action == 'share') {
        final fileBytes = await widget.clipboardRepository.downloadFile(item);
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
            '[MobileMain] ✅ Opened Share Sheet for ${item.contentType.value}',
          );
        } else {
          debugPrint('[MobileMain] ❌ Failed to download file for sharing');
          return false;
        }
      } else {
        // Text types (Plain, HTML, Markdown) - Copy to clipboard
        final clipboardService = ClipboardService.instance;

        switch (item.contentType) {
          case ContentType.html:
            await clipboardService.writeHtml(item.content);
            debugPrint('[MobileMain] ✅ Copied HTML to clipboard');
          case ContentType.markdown:
            await clipboardService.writeText(item.content);
            debugPrint('[MobileMain] ✅ Copied Markdown to clipboard');
          default: // Plain text
            await clipboardService.writeText(item.content);
            debugPrint('[MobileMain] ✅ Copied text to clipboard');
        }
      }

      return true;
    } on Exception catch (e) {
      debugPrint('[MobileMain] ❌ Error processing share action: $e');
      return false;
    }
  }

  StreamSubscription<List<SharedMediaFile>>? _intentDataStreamSubscription;

  void _initializeShareIntentListeners() {
    // 1. Listen for cached intents (app opened via share)
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        _handleSharedFiles(value);
      }
    });

    // 2. Listen for stream intents (app already running)
    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          (value) {
            if (value.isNotEmpty) {
              _handleSharedFiles(value);
            }
          },
          onError: (Object err) {
            debugPrint('getMediaStream error: $err');
          },
        );

    debugPrint('[ShareSheet] Share intent listeners initialized');
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    for (final file in files) {
      try {
        final path = file.path;
        if (path.isEmpty) continue;

        final bytes = await File(path).readAsBytes();
        final filename = path.split(Platform.pathSeparator).last;

        // Detect file type
        final fileTypeInfo = FileTypeService.instance.detectFromBytes(
          bytes,
          filename,
        );

        // Determine device type
        final deviceType = ClipboardRepository.getCurrentDeviceType();

        // Upload
        await widget.clipboardRepository.insertFile(
          userId: widget.authService.currentUserId!,
          deviceType: deviceType,
          deviceName: null,
          fileBytes: bytes,
          originalFilename: filename,
          contentType: fileTypeInfo.contentType,
          mimeType: fileTypeInfo.mimeType,
        );

        if (mounted) {
          showGhostToast(
            context,
            'Shared file uploaded: $filename',
            icon: Icons.upload_file,
            type: GhostToastType.success,
          );
        }
      } on Exception catch (e) {
        debugPrint('Error handling shared file: $e');
      }
    }
    // Refresh history
    unawaited(_loadHistory());
  }

  // Called by native share intent handlers (through method channels or plugins)
  // TODO: Wire up receive_sharing_intent package to call this method
  // ignore: unused_element
  Future<void> _handleSharedContent(String sharedContent) async {
    // Show device selector dialog
    final selectedDeviceTypes = await _showDeviceSelectorDialog(sharedContent);

    if (selectedDeviceTypes == null) {
      // User cancelled
      debugPrint('[ShareSheet] User cancelled share');
      return;
    }

    // Save to Supabase with selected device types
    await _saveSharedContent(sharedContent, selectedDeviceTypes);
  }

  Future<Set<String>?> _showDeviceSelectorDialog(String content) async {
    final selectedTypes = <String>{};

    return showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: GhostColors.surface,
            title: const Text(
              'Share to Devices',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: GhostColors.textPrimary,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select which device types to send to:',
                  style: const TextStyle(
                    fontSize: 13,
                    color: GhostColors.textMuted,
                  ),
                ),
                const SizedBox(height: 16),
                // Device type selector chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildDeviceChip(
                      'windows',
                      Icons.laptop_windows,
                      'Windows',
                      selectedTypes.contains('windows'),
                      () => setDialogState(() {
                        if (selectedTypes.contains('windows')) {
                          selectedTypes.remove('windows');
                        } else {
                          selectedTypes.add('windows');
                        }
                      }),
                    ),
                    _buildDeviceChip(
                      'macos',
                      Icons.laptop_mac,
                      'macOS',
                      selectedTypes.contains('macos'),
                      () => setDialogState(() {
                        if (selectedTypes.contains('macos')) {
                          selectedTypes.remove('macos');
                        } else {
                          selectedTypes.add('macos');
                        }
                      }),
                    ),
                    _buildDeviceChip(
                      'android',
                      Icons.phone_android,
                      'Android',
                      selectedTypes.contains('android'),
                      () => setDialogState(() {
                        if (selectedTypes.contains('android')) {
                          selectedTypes.remove('android');
                        } else {
                          selectedTypes.add('android');
                        }
                      }),
                    ),
                    _buildDeviceChip(
                      'ios',
                      Icons.phone_iphone,
                      'iOS',
                      selectedTypes.contains('ios'),
                      () => setDialogState(() {
                        if (selectedTypes.contains('ios')) {
                          selectedTypes.remove('ios');
                        } else {
                          selectedTypes.add('ios');
                        }
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  selectedTypes.isEmpty
                      ? 'Empty = All devices'
                      : '${selectedTypes.length} type(s) selected',
                  style: const TextStyle(
                    fontSize: 12,
                    color: GhostColors.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: Colors.grey.shade400),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(selectedTypes),
                child: const Text(
                  'Send',
                  style: TextStyle(color: GhostColors.primary),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDeviceChip(
    String deviceType,
    IconData icon,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? GhostColors.primary.withValues(alpha: 0.2)
              : GhostColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? GhostColors.primary : GhostColors.glassBorder,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? GhostColors.primary : GhostColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: isSelected ? GhostColors.primary : GhostColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSharedContent(
    String content,
    Set<String> selectedDeviceTypes,
  ) async {
    try {
      // Create clipboard item
      final item = ClipboardItem(
        id: '',
        userId: widget.authService.currentUserId ?? '',
        content: content,
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        targetDeviceTypes: selectedDeviceTypes.isEmpty
            ? null
            : selectedDeviceTypes.toList(),
        createdAt: DateTime.now(),
      );

      // Save to Supabase
      await widget.clipboardRepository.insert(item);

      if (mounted) {
        // Show success snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selectedDeviceTypes.isEmpty
                  ? 'Shared to all devices'
                  : 'Shared to ${selectedDeviceTypes.join(", ")}',
            ),
            backgroundColor: GhostColors.success,
            duration: const Duration(seconds: 2),
          ),
        );

        debugPrint('[ShareSheet] Content saved');
      }
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared content: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to share content'),
            backgroundColor: Colors.red.shade400,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _saveSharedImage(
    Uint8List imageBytes,
    String mimeType,
    Set<String> selectedDeviceTypes,
  ) async {
    try {
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
          debugPrint('[ShareSheet] ❌ Unsupported image type: $mimeType');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Unsupported image type: $mimeType'),
                backgroundColor: Colors.red.shade400,
                duration: const Duration(seconds: 2),
              ),
            );
          }
          return;
      }

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      // Upload image to Supabase
      await widget.clipboardRepository.insertImage(
        userId: widget.authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: selectedDeviceTypes.isEmpty
            ? null
            : selectedDeviceTypes.toList(),
      );

      if (mounted) {
        // Show success snackbar
        final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selectedDeviceTypes.isEmpty
                  ? 'Shared image ($sizeKB KB) to all devices'
                  : 'Shared image ($sizeKB KB) to ${selectedDeviceTypes.join(", ")}',
            ),
            backgroundColor: GhostColors.success,
            duration: const Duration(seconds: 2),
          ),
        );

        debugPrint('[ShareSheet] Image saved: $sizeKB KB');
      }
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to share image'),
            backgroundColor: Colors.red.shade400,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _saveSharedFile(
    Uint8List fileBytes,
    String mimeType,
    String filename,
    Set<String> selectedDeviceTypes,
  ) async {
    try {
      // Detect file type from bytes and filename
      final fileTypeInfo =
          FileTypeService.instance.detectFromBytes(fileBytes, filename);

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      // Upload file to Supabase
      await widget.clipboardRepository.insertFile(
        userId: widget.authService.currentUserId!,
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

      if (mounted) {
        // Show success snackbar
        final sizeKB = (fileBytes.length / 1024).toStringAsFixed(1);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selectedDeviceTypes.isEmpty
                  ? 'Shared $filename ($sizeKB KB) to all devices'
                  : 'Shared $filename ($sizeKB KB) to ${selectedDeviceTypes.join(", ")}',
            ),
            backgroundColor: GhostColors.success,
            duration: const Duration(seconds: 2),
          ),
        );

        debugPrint('[ShareSheet] File saved: $filename ($sizeKB KB)');
      }
    } on Exception catch (e) {
      debugPrint('[ShareSheet] Error saving shared file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to share file'),
            backgroundColor: Colors.red.shade400,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _loadDevices({bool forceRefresh = false}) async {
    setState(() => _devicesLoading = true);

    try {
      final devices = await widget.deviceService.getUserDevices(
        forceRefresh: forceRefresh,
      );
      if (mounted) {
        setState(() {
          _devices = devices;
          _devicesLoading = false;
        });
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to load devices: $e');
      if (mounted) {
        setState(() => _devicesLoading = false);
      }
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _historyLoading = true);

    try {
      // Mobile: Show only 10 most recent items in history tray (default limit)
      final items = await widget.clipboardRepository.getHistory();
      if (mounted) {
        setState(() {
          _historyItems = items;
          _filteredHistoryItems = items;
          _historyLoading = false;

          // Cleanup cache to prevent unbounded growth
          _cleanupCache();
        });

        // Update widget with latest clipboard data (non-blocking)
        // Run in background to avoid blocking UI
        unawaited(
          WidgetService().updateWidgetData(items).catchError((Object e) {
            debugPrint('[MobileMain] Failed to update widget: $e');
          }),
        );
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to load history: $e');
      if (mounted) {
        setState(() => _historyLoading = false);
      }
    }
  }

  /// Filter history based on search query with debouncing (performance optimization)
  /// Note: This method should be called within setState() by the caller
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

  /// Debounced wrapper for _filterHistory to reduce setState calls during typing
  void _filterHistoryDebounced(String query) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounceDelay, () {
      if (mounted) {
        setState(() => _filterHistory(query));
      }
    });
  }

  /// Clean up cache to prevent memory leaks
  /// Keeps only entries for current history items
  void _cleanupCache() {
    final currentIds = _historyItems.map((item) => item.id).toSet();

    // Remove cache entries for items no longer in history
    _decryptedContentCache.removeWhere((id, _) => !currentIds.contains(id));
    _detectionCache.removeWhere((id, _) => !currentIds.contains(id));

    // If cache is still too large, remove oldest entries (LRU)
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
  }

  void _subscribeToRealtimeUpdates() {
    // NOTE: This is a temporary solution for receiving clipboard items
    // TODO: Replace with FCM push notifications for production
    // FCM will trigger notifications when new clips are available
    // and allow auto-copy when notification is tapped
    //
    // Current implementation uses Realtime subscriptions as a placeholder
    // Mobile: Watch only 10 most recent items (default limit)
    // Supabase .stream() emits initial snapshot immediately, then updates on changes
    _historySubscription = widget.clipboardRepository.watchHistory().listen(
      (items) {
        if (mounted) {
          final oldFirstId = _historyItems.isNotEmpty
              ? _historyItems.first.id
              : null;

          setState(() {
            _historyItems = items;
            _filterHistory(_historySearchQuery);

            // Clear loading state (stream has emitted initial data)
            _historyLoading = false;

            // Cleanup cache after update
            _cleanupCache();
          });

          // Auto-copy latest item if it's from another device
          // Note: ClipboardItem doesn't have deviceId, so we auto-copy all new items
          if (items.isNotEmpty) {
            final latest = items.first;
            // Check if this is a new item (different from previous first item)
            if (oldFirstId == null || latest.id != oldFirstId) {
              _autoCopyToClipboard(latest);
            }
          }
        }
      },
      onError: (Object error) {
        debugPrint('[MobileMain] Realtime subscription error: $error');
        // Clear loading state on error
        if (mounted) {
          setState(() => _historyLoading = false);
        }
      },
    );
  }

  Future<void> _autoCopyToClipboard(ClipboardItem item) async {
    try {
      final clipboardService = ClipboardService.instance;

      if (item.isImage) {
        // For images, download from storage and copy to clipboard
        // Note: Images are NOT encrypted (too large for encryption)
        final bytes = await widget.clipboardRepository.downloadFile(item);
        if (bytes == null) {
          throw Exception('Failed to download image');
        }

        await clipboardService.writeImage(bytes);
        debugPrint(
          '[MobileMain] ✅ Auto-copied image to clipboard (${bytes.length} bytes)',
        );

        if (mounted) {
          showGhostToast(
            context,
            'Image copied from another device',
            icon: Icons.image,
            type: GhostToastType.success,
          );
        }
      } else if (item.isRichText) {
        // Rich text - decrypt if needed and copy with format
        var finalContent = item.content;
        if (_encryptionService != null) {
          finalContent = await _encryptionService!.decrypt(item.content);
        }

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          // Markdown - copy as plain text for now
          await clipboardService.writeText(finalContent);
        }

        debugPrint(
          '[MobileMain] ✅ Auto-copied ${item.richTextFormat?.value ?? "rich text"} to clipboard',
        );

        if (mounted) {
          showGhostToast(
            context,
            '${item.richTextFormat?.value ?? "Rich text"} copied from another device',
            icon: Icons.sync,
            type: GhostToastType.success,
          );
        }
      } else {
        // Plain text - decrypt if needed and copy
        var finalContent = item.content;
        if (_encryptionService != null) {
          finalContent = await _encryptionService!.decrypt(item.content);
        }

        await clipboardService.writeText(finalContent);
        debugPrint('[MobileMain] ✅ Auto-copied text to clipboard');

        if (mounted) {
          showGhostToast(
            context,
            'Clipboard updated from another device',
            icon: Icons.sync,
            type: GhostToastType.success,
          );
        }
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to auto-copy: $e');
    }
  }

  Future<void> _handleSend() async {
    // Check if sending image or text
    if (_clipboardContent?.hasImage ?? false) {
      // Send image
      await _sendImage();
      return;
    }

    final content = _pasteController.text.trim();
    if (content.isEmpty) {
      setState(() => _sendError = 'Please paste or type content to send');
      return;
    }

    // Security check
    final securityResult = widget.securityService.detectSensitiveData(content);
    if (securityResult.isSensitive) {
      final shouldContinue = await _showSensitiveDataWarning();
      if (!shouldContinue) return;
    }

    setState(() {
      _isSending = true;
      _sendError = null;
    });

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

      // Create clipboard item to send
      // Note: id will be set by database
      final item = ClipboardItem(
        id: '', // Will be set by database
        userId: widget.authService.currentUserId ?? '',
        deviceType:
            ClipboardRepository.getCurrentDeviceType(), // Platform-specific: 'android' or 'ios'
        content: finalContent,
        targetDeviceTypes: targetTypes,
        createdAt: DateTime.now(),
      );

      // Send to clipboard
      await widget.clipboardRepository.insert(item);

      debugPrint('[MobileMain] ✅ Sent clipboard item');

      // Clear paste area and show success
      if (mounted) {
        _pasteController.clear();
        _clipboardContent = null; // Clear image content
        setState(() => _isSending = false);

        showGhostToast(
          context,
          'Sent successfully',
          icon: Icons.send,
          type: GhostToastType.success,
        );

        // Reload history to show new item and update widget (non-blocking)
        unawaited(_loadHistory());

        // Security: Schedule clipboard auto-clear
        _lastSendWasFromPaste = true;
        await _scheduleClipboardClear();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to send: $e');
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendError = 'Failed to send: $e';
        });
      }
    }
  }

  /// Send image from clipboard content
  Future<void> _sendImage() async {
    if (_clipboardContent?.hasImage != true) return;

    setState(() {
      _isSending = true;
      _sendError = null;
    });

    try {
      final imageBytes = _clipboardContent!.imageBytes!;
      final mimeType = _clipboardContent!.mimeType!;

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
          setState(() {
            _isSending = false;
            _sendError = 'Unsupported image type: $mimeType';
          });
          return;
      }

      // Determine target devices
      List<String>? targetTypes;
      if (_selectedDeviceTypes.isNotEmpty) {
        targetTypes = _selectedDeviceTypes.toList();
      }

      final deviceType = ClipboardRepository.getCurrentDeviceType();

      // Send image
      await widget.clipboardRepository.insertImage(
        userId: widget.authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        imageBytes: imageBytes,
        mimeType: mimeType,
        contentType: contentType,
        targetDeviceTypes: targetTypes,
      );

      debugPrint(
        '[MobileMain] ✅ Sent image (${(imageBytes.length / 1024).toStringAsFixed(1)} KB)',
      );

      // Clear paste area and show success
      if (mounted) {
        _pasteController.clear();
        setState(() {
          _clipboardContent = null;
          _isSending = false;
        });

        showGhostToast(
          context,
          'Image sent successfully',
          icon: Icons.image,
          type: GhostToastType.success,
        );

        // Reload history to show new item and update widget (non-blocking)
        unawaited(_loadHistory());

        // Security: Schedule clipboard auto-clear
        _lastSendWasFromPaste = true;
        await _scheduleClipboardClear();
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to send image: $e');
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendError = 'Failed to send image: $e';
        });
      }
    }
  }

  /// Schedule clipboard clearing based on user settings
  Future<void> _scheduleClipboardClear() async {
    // Cancel any existing timer
    _clipboardClearTimer?.cancel();

    // Get user's auto-clear duration setting
    final clearSeconds = await widget.settingsService
        .getClipboardAutoClearSeconds();

    if (clearSeconds == 0) {
      debugPrint('[MobileMain] Clipboard auto-clear disabled');
      return;
    }

    debugPrint(
      '[MobileMain] Clipboard will be cleared in $clearSeconds seconds',
    );

    _clipboardClearTimer = Timer(
      Duration(seconds: clearSeconds),
      _clearClipboardNow,
    );
  }

  /// Immediately clear the system clipboard
  void _clearClipboardNow() {
    ClipboardService.instance.clear();
    _lastSendWasFromPaste = false;
    debugPrint('[MobileMain] System clipboard cleared for security');
  }

  Future<void> _handleImageUpload() async {
    // Prevent double-tap
    if (_isUploadingImage) {
      return;
    }

    setState(() {
      _isUploadingImage = true;
    });

    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        maxHeight: 2048,
      );

      if (image == null) {
        // User cancelled
        setState(() {
          _isUploadingImage = false;
        });
        return;
      }

      // Read image bytes
      final bytes = await image.readAsBytes();

      // Determine mime type and content type
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
        // Default to JPEG
        mimeType = 'image/jpeg';
        contentType = ContentType.imageJpeg;
      }

      // Upload image
      await widget.clipboardRepository.insertImage(
        userId: widget.authService.currentUserId ?? '',
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        deviceName: null,
        imageBytes: bytes,
        mimeType: mimeType,
        contentType: contentType,
      );

      if (mounted) {
        showGhostToast(
          context,
          'Image uploaded successfully',
          icon: Icons.check_circle,
          type: GhostToastType.success,
        );

        // Reload history to show new item and update widget (non-blocking)
        unawaited(_loadHistory());
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to upload image: $e');
      if (mounted) {
        showGhostToast(
          context,
          'Failed to upload image: $e',
          icon: Icons.error,
          type: GhostToastType.error,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
      }
    }
  }

  Future<bool> _showSensitiveDataWarning() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GhostColors.surface,
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange.shade400,
              size: 24,
            ),
            const SizedBox(width: 12),
            const Text(
              'Sensitive Data Detected',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: GhostColors.textPrimary,
              ),
            ),
          ],
        ),
        content: const Text(
          'This content may contain sensitive information (passwords, API keys, etc.). Are you sure you want to sync it?',
          style: TextStyle(fontSize: 14, color: GhostColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.orange.shade400,
            ),
            child: const Text('Send Anyway'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<void> _handleRefresh() async {
    await Future.wait([_loadDevices(forceRefresh: true), _loadHistory()]);
  }

  Future<void> _handleHistoryItemTap(ClipboardItem item) async {
    try {
      final clipboardService = ClipboardService.instance;

      // Handle different content types
      // Handle different content types
      if (item.isImage || item.isFile) {
        // Image OR File - Download to temp and share via system sheet
        // Requirement: "history view needs to have the ability to display similar to dekstop all file types and now we handle tap to copy in the hisotry view with share sheet to export out right instead of tap to copy to clipboard for images and files"
        final fileBytes = await widget.clipboardRepository.downloadFile(item);
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

        // Share using share_plus
        // ignore: deprecated_member_use
        await Share.shareXFiles([
          XFile(tempFile.path),
        ], text: 'Shared via GhostCopy');
      } else if (item.isRichText) {
        // Rich text - use cached decrypted content if available, or decrypt
        var finalContent = _decryptedContentCache[item.id] ?? item.content;

        // Only decrypt if not in cache and encryption is enabled
        if (_decryptedContentCache[item.id] == null &&
            _encryptionService != null &&
            item.isEncrypted) {
          try {
            finalContent = await _encryptionService!.decrypt(item.content);
            _decryptedContentCache[item.id] = finalContent;
          } on Exception catch (e) {
            debugPrint('[MobileMain] Decryption failed, using raw content: $e');
            finalContent = item.content;
          }
        }

        if (item.richTextFormat == RichTextFormat.html) {
          await clipboardService.writeHtml(finalContent);
        } else {
          // Markdown - copy as plain text for now
          await clipboardService.writeText(finalContent);
        }

        if (mounted) {
          showGhostToast(
            context,
            'Copied ${item.richTextFormat?.value ?? "rich text"}',
            icon: Icons.copy,
            type: GhostToastType.success,
            duration: const Duration(seconds: 1),
          );
        }
      } else {
        // Plain text - use cached decrypted content if available, or decrypt
        var finalContent = _decryptedContentCache[item.id] ?? item.content;

        // Only decrypt if not in cache and encryption is enabled
        if (_decryptedContentCache[item.id] == null &&
            _encryptionService != null &&
            item.isEncrypted) {
          try {
            finalContent = await _encryptionService!.decrypt(item.content);
            _decryptedContentCache[item.id] = finalContent;
          } on Exception catch (e) {
            debugPrint('[MobileMain] Decryption failed, using raw content: $e');
            finalContent = item.content;
          }
        }

        await clipboardService.writeText(finalContent);

        if (mounted) {
          showGhostToast(
            context,
            'Copied to clipboard',
            icon: Icons.copy,
            type: GhostToastType.success,
            duration: const Duration(seconds: 1),
          );
        }
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to copy: $e');
      if (mounted) {
        showGhostToast(
          context,
          'Failed to copy: $e',
          icon: Icons.error,
          type: GhostToastType.error,
        );
      }
    }
  }

  Future<void> _handleFilePick() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null) return;

      final file = result.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();

      // Validate file size (10MB limit)
      if (bytes.length > 10485760) {
        if (mounted) {
          showGhostToast(
            context,
            'File too large: ${file.name} (max 10MB)',
            icon: Icons.error_outline,
            type: GhostToastType.error,
          );
        }
        return;
      }

      // Warn for large files (>5MB)
      if (bytes.length > 5242880) {
        if (mounted) {
          final sizeMB = (bytes.length / 1048576).toStringAsFixed(1);
          final shouldContinue = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: GhostColors.surface,
              title: const Text(
                'Large File Warning',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: GhostColors.textPrimary,
                ),
              ),
              content: Text(
                'This file is $sizeMB MB. Upload may take 10-20 seconds.\n\nContinue?',
                style: const TextStyle(
                  fontSize: 14,
                  color: GhostColors.textMuted,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Upload'),
                ),
              ],
            ),
          ) ?? false;

          if (!shouldContinue) {
            return;
          }
        }
      }

      // Determine device type
      final deviceType = ClipboardRepository.getCurrentDeviceType();

      // Detect file type
      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        bytes,
        file.name,
      );

      // Upload file
      await widget.clipboardRepository.insertFile(
        userId: widget.authService.currentUserId!,
        deviceType: deviceType,
        deviceName: null,
        fileBytes: bytes,
        originalFilename: file.name,
        contentType: fileTypeInfo.contentType,
        mimeType: fileTypeInfo.mimeType,
      );

      if (mounted) {
        showGhostToast(
          context,
          'File uploaded: ${file.name}',
          icon: Icons.upload_file,
          type: GhostToastType.success,
        );
        unawaited(_loadHistory());
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] File pick failed: $e');
      if (mounted) {
        showGhostToast(
          context,
          'Failed to upload file',
          icon: Icons.error,
          type: GhostToastType.error,
        );
      }
    }
  }

  Future<void> _navigateToSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MobileSettingsScreen(
          authService: widget.authService,
          deviceService: widget.deviceService,
          settingsService: widget.settingsService,
        ),
      ),
    );

    // Refresh history when returning from settings (encryption keys may have changed)
    if (mounted) {
      // Clear caches to force re-decryption with new keys
      _decryptedContentCache.clear();
      _detectionCache.clear();
      await _loadHistory();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GhostColors.background,
      appBar: AppBar(
        backgroundColor: GhostColors.surface,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: GhostColors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.content_copy_rounded,
                size: 18,
                color: GhostColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'GhostCopy',
              style: GhostTypography.headline.copyWith(fontSize: 18),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _navigateToSettings,
            color: GhostColors.textSecondary,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _handleFilePick,
        backgroundColor: GhostColors.primary,
        child: const Icon(Icons.attach_file, color: Colors.white),
      ),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: GhostColors.primary,
        backgroundColor: GhostColors.surface,
        child: CustomScrollView(
          slivers: [
            // Paste area section
            SliverToBoxAdapter(child: _buildPasteArea()),

            // Device selector chips
            SliverToBoxAdapter(child: _buildDeviceSelector()),

            // Send button
            SliverToBoxAdapter(child: _buildSendButton()),

            // History section header
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Row(
                  children: [
                    Text(
                      'History',
                      style: GhostTypography.headline.copyWith(fontSize: 16),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: GhostColors.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: GhostColors.primary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        '10 recent',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: GhostColors.primary.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Search bar
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: TextField(
                  controller: _historySearchController,
                  onChanged: _filterHistoryDebounced,
                  style: const TextStyle(
                    fontSize: 14,
                    color: GhostColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Search clips...',
                    hintStyle: TextStyle(
                      color: GhostColors.textMuted.withValues(alpha: 0.6),
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      size: 18,
                      color: GhostColors.textMuted,
                    ),
                    suffixIcon: _historySearchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _historySearchController.clear();
                              setState(() => _filterHistory(''));
                            },
                            color: GhostColors.textMuted,
                          )
                        : null,
                    filled: true,
                    fillColor: GhostColors.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: GhostColors.glassBorder,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: GhostColors.glassBorder,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                        color: GhostColors.primary,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // History list
            _buildHistoryList(),
          ],
        ),
      ),
    );
  }

  /// Build image preview for paste area (when clipboard contains image)
  Widget _buildImagePreview() {
    if (_clipboardContent?.hasImage != true ||
        _clipboardContent?.imageBytes == null) {
      return const SizedBox.shrink();
    }

    final imageBytes = _clipboardContent!.imageBytes!;
    final mimeType = _clipboardContent!.mimeType ?? 'unknown';
    final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GhostColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          // Image thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 80),
              child: Image.memory(
                imageBytes,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    height: 80,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.broken_image,
                      size: 40,
                      color: GhostColors.textMuted,
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Image info
          Text(
            '${mimeType.split('/').last.toUpperCase()} • $sizeKB KB',
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasteArea() {
    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.paste_outlined,
                  size: 18,
                  color: GhostColors.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Paste & Send',
                  style: GhostTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Image preview (if clipboard has image)
          if (_clipboardContent?.hasImage ?? false) _buildImagePreview(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _pasteController,
              maxLines: 4,
              style: const TextStyle(
                fontSize: 14,
                color: GhostColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Paste or type content here...',
                hintStyle: TextStyle(
                  color: GhostColors.textMuted.withValues(alpha: 0.6),
                ),
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (value) {
                // Clear error when user types
                if (_sendError != null) {
                  setState(() => _sendError = null);
                }
              },
            ),
          ),
          // Upload button row
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: _handleImageUpload,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  color: GhostColors.primary,
                  iconSize: 20,
                  tooltip: 'Upload image',
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          if (_sendError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 14,
                    color: Colors.red.shade400,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _sendError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade400,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Send to',
            style: GhostTypography.caption.copyWith(
              color: GhostColors.textMuted,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: _devicesLoading
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: GhostColors.primary,
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _devices.length + 1, // +1 for "All Devices"
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      // "All Devices" chip
                      return _DeviceChip(
                        label: 'All Devices',
                        icon: Icons.devices,
                        isSelected: _selectedDeviceTypes.isEmpty,
                        onTap: () => setState(_selectedDeviceTypes.clear),
                      );
                    }

                    final device = _devices[index - 1];
                    final isSelected = _selectedDeviceTypes.contains(
                      device.deviceType,
                    );

                    return _DeviceChip(
                      label: device.displayName,
                      icon: _getDeviceIcon(device.deviceType),
                      isSelected: isSelected,
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedDeviceTypes.remove(device.deviceType);
                          } else {
                            _selectedDeviceTypes.add(device.deviceType);
                          }
                        });
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSendButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
          onPressed: _isSending ? null : _handleSend,
          style: FilledButton.styleFrom(
            backgroundColor: GhostColors.primary,
            disabledBackgroundColor: GhostColors.primary.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: _isSending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.send_rounded, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _selectedDeviceTypes.isEmpty
                          ? 'Send to All Devices'
                          : 'Send to ${_selectedDeviceTypes.length} Device${_selectedDeviceTypes.length > 1 ? 's' : ''}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildHistoryList() {
    if (_historyLoading) {
      return const SliverFillRemaining(
        child: Center(
          child: CircularProgressIndicator(color: GhostColors.primary),
        ),
      );
    }

    if (_filteredHistoryItems.isEmpty) {
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.content_paste_off_outlined,
                size: 48,
                color: GhostColors.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                _historySearchQuery.isNotEmpty
                    ? 'No clips match your search'
                    : 'No clipboard history yet',
                style: GhostTypography.body.copyWith(
                  color: GhostColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = _filteredHistoryItems[index];

          // Use cached decrypted content if available
          final cachedDecrypted = _decryptedContentCache[item.id];
          final cachedDetection = _detectionCache[item.id];

          return RepaintBoundary(
            child: _StaggeredHistoryItem(
              key: ValueKey(item.id), // Stable key for performance
              index: index,
              item: item,
              transformerService: widget.transformerService,
              clipboardRepository: widget.clipboardRepository,
              encryptionService: _encryptionService,
              cachedDecryptedContent: cachedDecrypted,
              cachedDetectionResult: cachedDetection,
              onContentDecrypted: (content) {
                // Cache decrypted content
                _decryptedContentCache[item.id] = content;
              },
              onContentDetected: (result) {
                // Cache detection result
                _detectionCache[item.id] = result;
              },
              onTap: () => _handleHistoryItemTap(item),
            ),
          );
        }, childCount: _filteredHistoryItems.length),
      ),
    );
  }

  IconData _getDeviceIcon(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'windows':
        return Icons.laptop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.laptop_chromebook;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }
}

/// Device selection chip widget
class _DeviceChip extends StatelessWidget {
  const _DeviceChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? GhostColors.primary : GhostColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected ? GhostColors.primary : GhostColors.glassBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : GhostColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: isSelected ? Colors.white : GhostColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Staggered history item with fade-in and slide animation
/// Includes smart transformer detection and preview mode
///
/// Performance optimizations:
/// - Uses cached decrypted content to avoid re-decryption
/// - Uses cached detection results to avoid re-detection
/// - Stable ValueKey for efficient list updates
/// - RepaintBoundary wrapper prevents unnecessary repaints
class _StaggeredHistoryItem extends StatefulWidget {
  const _StaggeredHistoryItem({
    required this.index,
    required this.item,
    required this.transformerService,
    required this.clipboardRepository,
    required this.onTap,
    super.key,
    this.encryptionService,
    this.cachedDecryptedContent,
    this.cachedDetectionResult,
    this.onContentDecrypted,
    this.onContentDetected,
  });

  final int index;
  final ClipboardItem item;
  final ITransformerService transformerService;
  final IClipboardRepository clipboardRepository;
  final EncryptionService? encryptionService;
  final String? cachedDecryptedContent;
  final ContentDetectionResult? cachedDetectionResult;
  final ValueChanged<String>? onContentDecrypted;
  final ValueChanged<ContentDetectionResult>? onContentDetected;
  final VoidCallback onTap;

  @override
  State<_StaggeredHistoryItem> createState() => _StaggeredHistoryItemState();
}

class _StaggeredHistoryItemState extends State<_StaggeredHistoryItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  bool _isExpanded = false;

  // Content detection and preview mode
  ContentDetectionResult? _detectionResult;
  String? _decryptedContent;
  bool _isPreviewMode = false; // For large JSON/JWT payloads

  @override
  void didUpdateWidget(_StaggeredHistoryItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-run detection if content, cache, or encryption service changes
    if (widget.item.content != oldWidget.item.content ||
        widget.cachedDecryptedContent != oldWidget.cachedDecryptedContent ||
        widget.encryptionService != oldWidget.encryptionService) {
      _initializeContentDetection();
    }
  }

  @override
  void initState() {
    super.initState();

    // Staggered animation: each item starts with a delay
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // Stagger delay: 50ms per item (max 500ms)
    Future<void>.delayed(
      Duration(milliseconds: (widget.index * 50).clamp(0, 500)),
      () {
        if (mounted) {
          _controller.forward();
        }
      },
    );

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.2), // Slide up slightly
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    // Detect content type and decrypt if needed
    _initializeContentDetection();
  }

  Future<void> _initializeContentDetection() async {
    // Performance: Use cached values if available
    if (widget.cachedDecryptedContent != null) {
      _decryptedContent = widget.cachedDecryptedContent;

      if (widget.cachedDetectionResult != null) {
        // Both cached, use directly
        _detectionResult = widget.cachedDetectionResult;
        _isPreviewMode =
            (widget.cachedDetectionResult!.type ==
                    TransformerContentType.json ||
                widget.cachedDetectionResult!.type ==
                    TransformerContentType.jwt) &&
            widget.cachedDecryptedContent!.length > 200;

        if (mounted) {
          setState(() {});
        }
        return;
      }
    }

    // Decrypt content if encryption service is available and not cached
    var content = widget.item.content;
    if (_decryptedContent == null && widget.encryptionService != null) {
      try {
        content = await widget.encryptionService!.decrypt(content);
        _decryptedContent = content;

        // Notify parent to cache
        widget.onContentDecrypted?.call(content);

        if (mounted) {
          setState(() {});
        }
      } on Exception catch (e) {
        debugPrint('[HistoryItem] Failed to decrypt: $e');
        _decryptedContent = content;
      }
    } else {
      _decryptedContent = content;
    }

    // Detect content type (Requirements 7.1, 7.2, 7.3)
    // Only if not cached
    if (_detectionResult == null) {
      final detectionResult = await widget.transformerService.detectContentType(
        _decryptedContent ?? content,
      );

      if (!mounted) return;

      _detectionResult = detectionResult;

      // Notify parent to cache
      widget.onContentDetected?.call(detectionResult);

      // Enable preview mode for JSON/JWT content longer than 200 chars
      _isPreviewMode =
          (detectionResult.type == TransformerContentType.json ||
              detectionResult.type == TransformerContentType.jwt) &&
          (_decryptedContent ?? content).length > 200;

      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _formatTimeAgo(DateTime timestamp) {
    return timeago.format(timestamp, locale: 'en_short');
  }

  String _getDeviceLabel(String deviceType) {
    return deviceType[0].toUpperCase() + deviceType.substring(1);
  }

  /// Build content preview based on content type (text, image, or rich text)
  Widget _buildContentPreview(String displayContent) {
    // Image preview
    if (widget.item.isImage) {
      return _buildImagePreview();
    }

    // File preview
    if (widget.item.isFile) {
      return _buildFilePreview();
    }

    // Rich text preview
    if (widget.item.isRichText) {
      return _buildRichTextPreview(displayContent);
    }

    // Normal text (with transformer detection)
    return Text(
      displayContent,
      maxLines: _isExpanded ? null : (_isPreviewMode ? 3 : 2),
      overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 14,
        color: GhostColors.textPrimary,
        fontFamily:
            _detectionResult?.type == TransformerContentType.json ||
                _detectionResult?.type == TransformerContentType.jwt
            ? 'JetBrainsMono'
            : null,
      ),
    );
  }

  /// Build image preview widget
  Widget _buildImagePreview() {
    // Use CDN-backed widget with automatic fallback to storage download
    return CachedClipboardImage(
      item: widget.item,
      clipboardRepository: widget.clipboardRepository,
      height: 120,
      width: double.infinity,
    );
  }

  /// Build file preview widget
  Widget _buildFilePreview() {
    final filename = widget.item.metadata?.originalFilename ?? 'Unknown File';
    final size = widget.item.displaySize;
    final ext = filename.split('.').last.toUpperCase();
    final fileColor = _getFileColor(ext);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fileColor.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: fileColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(_getFileIcon(ext), color: fileColor, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filename,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: GhostColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '$ext • $size',
                  style: const TextStyle(
                    fontSize: 12,
                    color: GhostColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.share_outlined,
            color: GhostColors.textMuted,
            size: 20,
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String ext) {
    switch (ext) {
      case 'PDF':
        return Icons.picture_as_pdf_rounded;
      case 'ZIP':
      case 'RAR':
      case '7Z':
      case 'TAR':
      case 'GZ':
        return Icons.folder_zip_rounded;
      case 'DOC':
      case 'DOCX':
        return Icons.description_rounded;
      case 'XLS':
      case 'XLSX':
      case 'CSV':
        return Icons.table_chart_rounded;
      case 'PPT':
      case 'PPTX':
        return Icons.slideshow_rounded;
      case 'MP3':
      case 'WAV':
      case 'M4A':
      case 'AAC':
      case 'OGG':
        return Icons.audio_file_rounded;
      case 'MP4':
      case 'MOV':
      case 'MKV':
      case 'AVI':
      case 'WEBM':
        return Icons.video_file_rounded;
      case 'Js':
      case 'TS':
      case 'PY':
      case 'DART':
      case 'HTML':
      case 'CSS':
      case 'JSON':
      case 'XML':
      case 'YAML':
      case 'YML':
        return Icons.code_rounded;
      case 'TXT':
      case 'MD':
      case 'RTF':
        return Icons.text_snippet_rounded;
      case 'EXE':
      case 'DMG':
      case 'ISO':
      case 'MSI':
      case 'APK':
        return Icons.install_desktop_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color _getFileColor(String ext) {
    switch (ext) {
      case 'PDF':
        return Colors.red.shade400;
      case 'ZIP':
      case 'RAR':
      case '7Z':
      case 'TAR':
      case 'GZ':
        return Colors.orange.shade400;
      case 'XLS':
      case 'XLSX':
      case 'CSV':
        return Colors.green.shade400;
      case 'PPT':
      case 'PPTX':
        return Colors.orange.shade700;
      case 'MP3':
      case 'WAV':
      case 'M4A':
      case 'AAC':
      case 'OGG':
        return Colors.purple.shade400;
      case 'MP4':
      case 'MOV':
      case 'MKV':
      case 'AVI':
      case 'WEBM':
        return Colors.red.shade600;
      case 'JS':
      case 'TS':
      case 'PY':
      case 'DART':
      case 'HTML':
      case 'CSS':
      case 'JSON':
      case 'XML':
      case 'YAML':
      case 'YML':
        return Colors.blue.shade400;
      case 'EXE':
      case 'DMG':
      case 'ISO':
      case 'MSI':
      case 'APK':
        return Colors.teal.shade400;
      case 'DOC':
      case 'DOCX':
        return Colors.blue.shade600;
      default:
        return GhostColors.primary;
    }
  }

  /// Build rich text preview widget
  Widget _buildRichTextPreview(String content) {
    final format = widget.item.richTextFormat;
    final icon = format == RichTextFormat.html ? Icons.code : Icons.text_fields;
    final label = format == RichTextFormat.html ? 'HTML' : 'Markdown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Badge showing format type
        Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: GhostColors.primary.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: GhostColors.primary.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Content preview
        Text(
          content,
          maxLines: _isExpanded ? null : 3,
          overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            color: GhostColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  IconData _getDeviceIcon(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'windows':
        return Icons.laptop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'linux':
        return Icons.laptop_chromebook;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayContent = _decryptedContent ?? widget.item.content;
    final shouldShowExpand = displayContent.length > 100;

    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: GhostColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: GhostColors.glassBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Content preview with expand button and preview mode badge
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Preview mode badge for large JSON/JWT
                            if (_isPreviewMode && !_isExpanded)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  children: [
                                    Icon(
                                      _detectionResult?.type ==
                                              TransformerContentType.json
                                          ? Icons.code
                                          : Icons.lock_open,
                                      size: 12,
                                      color: GhostColors.primary.withValues(
                                        alpha: 0.8,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Preview Mode',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: GhostColors.primary.withValues(
                                          alpha: 0.8,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Content preview (text, image, or rich text)
                            _buildContentPreview(displayContent),
                          ],
                        ),
                      ),
                      // Expand button (show if content is long)
                      if (shouldShowExpand) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () =>
                              setState(() => _isExpanded = !_isExpanded),
                          child: AnimatedRotation(
                            turns: _isExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.expand_more,
                              size: 18,
                              color: GhostColors.primary.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),

                  // Smart Action Buttons (Requirements 7.1, 7.2, 7.3, 7.4)
                  if (_detectionResult != null)
                    SmartActionButtons(
                      content: displayContent,
                      detectionResult: _detectionResult!,
                      transformerService: widget.transformerService,
                    ),

                  const SizedBox(height: 10),
                  // Metadata row
                  Row(
                    children: [
                      // Source device
                      Icon(
                        _getDeviceIcon(widget.item.deviceType),
                        size: 13,
                        color: GhostColors.textMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _getDeviceLabel(widget.item.deviceType),
                        style: const TextStyle(
                          fontSize: 12,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Time ago
                      Icon(
                        Icons.access_time,
                        size: 13,
                        color: GhostColors.textMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _formatTimeAgo(widget.item.createdAt),
                        style: const TextStyle(
                          fontSize: 12,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      // Target devices indicator
                      if (widget.item.targetDeviceTypes != null &&
                          widget.item.targetDeviceTypes!.isNotEmpty) ...[
                        const Spacer(),
                        Icon(
                          Icons.arrow_forward,
                          size: 11,
                          color: GhostColors.primary.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 5),
                        Icon(
                          Icons.devices,
                          size: 13,
                          color: GhostColors.primary.withValues(alpha: 0.7),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
