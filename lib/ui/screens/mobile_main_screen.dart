import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../locator.dart';
import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/file_type_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/transformer_service.dart';
import '../platform_adaptive.dart';
import '../theme/colors.dart';
import '../theme/spacing.dart';
import '../theme/typography.dart';
import '../viewmodels/mobile_main_viewmodel.dart';
import '../widgets/cached_clipboard_image.dart';
import '../widgets/ghost_toast.dart';
import '../widgets/native_toast.dart';
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
  const MobileMainScreen({super.key});

  @override
  State<MobileMainScreen> createState() => _MobileMainScreenState();
}

class _MobileMainScreenState extends State<MobileMainScreen>
    with WidgetsBindingObserver {
  late final MobileMainViewModel _viewModel;
  late final ITransformerService _transformerService =
      locator<ITransformerService>();
  late final IClipboardRepository _clipboardRepository =
      locator<IClipboardRepository>();
  bool _isRebuildScheduled = false;
  final FocusNode _pasteFocusNode = FocusNode();
  bool _composerFocused = false;

  // Flutter platform widgets (must stay in widget)
  final TextEditingController _pasteController = TextEditingController();
  final TextEditingController _historySearchController =
      TextEditingController();
  final ValueNotifier<String?> _sendError = ValueNotifier(null);

  // Share intent subscription
  StreamSubscription<List<SharedMediaFile>>? _intentDataStreamSubscription;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Assign the field BEFORE starting initialize(). A cascade
    // (`_viewModel = VM()..addListener()..initialize()`) only assigns once the
    // whole expression finishes, and initialize() now calls notifyListeners()
    // before its first await - so the listener fired while _viewModel was
    // still unset and threw LateInitializationError. Splitting the statements
    // removes the dependency on initialize()'s internal await timing.
    _viewModel = MobileMainViewModel(
      authService: locator(),
      clipboardRepository: locator(),
      deviceService: locator(),
      securityService: locator(),
      settingsService: locator(),
    );
    _viewModel.addListener(_onViewModelChanged);
    unawaited(_viewModel.initialize());

    // Focus drives the composer's border colour, so the surface itself shows
    // focus instead of the text field drawing its own outline.
    _pasteFocusNode.addListener(() {
      if (_pasteFocusNode.hasFocus != _composerFocused && mounted) {
        setState(() => _composerFocused = _pasteFocusNode.hasFocus);
      }
    });

    _initializeShareIntentListeners();
    _setupMethodChannels();
    _initDeepLinks();
  }

  void _onViewModelChanged() {
    // Sync send error from ViewModel to ValueNotifier for fine-grained rebuilds
    if (_sendError.value != _viewModel.sendErrorMessage) {
      _sendError.value = _viewModel.sendErrorMessage;
    }

    _scheduleRebuild();
  }

  void _scheduleRebuild() {
    if (!mounted || _isRebuildScheduled) return;

    _isRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isRebuildScheduled = false;
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pasteFocusNode.dispose();
    _viewModel
      ..removeListener(_onViewModelChanged)
      ..dispose();

    _pasteController.dispose();
    _historySearchController.dispose();
    _sendError.dispose();
    _intentDataStreamSubscription?.cancel();
    _linkSubscription?.cancel();

    // Remove method channel handlers to prevent memory leaks
    _shareChannel.setMethodCallHandler(null);
    _notificationChannel.setMethodCallHandler(null);

    super.dispose();
  }

  /// Handle app lifecycle changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _viewModel.onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      _viewModel.onAppResumed();
      // Auto-paste from clipboard
      _populateFromClipboard();
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    _viewModel.onMemoryPressure();

    // Clear Flutter image caches (framework-level, not in ViewModel)
    imageCache
      ..clear()
      ..clearLiveImages();
  }

  Future<void> _populateFromClipboard() async {
    final result = await _viewModel.populateFromClipboard();
    if (result != null && mounted) {
      _pasteController.text = result.$1;
      _pasteController.selection = TextSelection.fromPosition(
        TextPosition(offset: result.$1.length),
      );

      // Precache image to avoid re-decoding on rebuilds
      if ((result.$2?.hasImage ?? false) && mounted) {
        unawaited(precacheImage(MemoryImage(result.$2!.imageBytes!), context));
      }
    }
  }

  void _clearPendingAttachmentPreview() {
    final hasAttachment =
        (_viewModel.clipboardContent?.hasImage ?? false) ||
        (_viewModel.clipboardContent?.hasFile ?? false);
    if (!hasAttachment) {
      return;
    }

    final currentText = _pasteController.text.trim();
    final isGeneratedAttachmentText =
        currentText.startsWith('[Image: ') || currentText.startsWith('[File: ');

    _viewModel.clearPendingAttachment();
    if (isGeneratedAttachmentText) {
      _pasteController.clear();
    }
    debugPrint('[MobileMain] Cleared pending attachment preview');
  }

  /// Offer image or file in one place.
  ///
  /// Previously these were two separate controls - an icon by the paste box and
  /// a floating action button - that behaved differently: the image one staged
  /// a preview, the file one uploaded immediately and ignored the device chips.
  /// Both now stage an attachment and are sent with the Send button.
  Future<void> _showAttachSheet() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: GhostColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: GhostColors.textMutedAlpha50,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(
                Icons.add_photo_alternate_outlined,
                color: GhostColors.primary,
              ),
              title: const Text(
                'Image',
                style: TextStyle(color: GhostColors.textPrimary),
              ),
              subtitle: const Text(
                'Pick from your gallery',
                style: TextStyle(color: GhostColors.textMuted, fontSize: 12),
              ),
              onTap: () => Navigator.of(context).pop('image'),
            ),
            ListTile(
              leading: const Icon(
                Icons.insert_drive_file_outlined,
                color: GhostColors.primary,
              ),
              title: const Text(
                'File',
                style: TextStyle(color: GhostColors.textPrimary),
              ),
              subtitle: const Text(
                'Any file up to 10MB',
                style: TextStyle(color: GhostColors.textMuted, fontSize: 12),
              ),
              onTap: () => Navigator.of(context).pop('file'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) return;

    if (choice == 'image') {
      await _viewModel.handleImageUpload(
        onSuccess: () {
          if (mounted) {
            showGhostToast(
              context,
              'Image attached - press Send',
              icon: Icons.image_outlined,
              type: GhostToastType.success,
            );
          }
        },
        onError: (msg) {
          if (mounted) {
            showGhostToast(
              context,
              msg,
              icon: Icons.error,
              type: GhostToastType.error,
            );
          }
        },
      );
      return;
    }

    await _viewModel.handleFilePick(
      onLargeFileConfirm: (sizeMB) async {
        if (!mounted) return false;
        return Adaptive.confirm(
          context,
          title: 'Large File',
          message:
              'This file is $sizeMB MB. Upload may take 10-20 seconds.\n\nContinue?',
          confirmText: 'Attach',
        );
      },
      onSuccess: (filename) {
        if (mounted) {
          showGhostToast(
            context,
            '$filename attached - press Send',
            icon: Icons.attach_file,
            type: GhostToastType.success,
          );
        }
      },
      onError: (msg) {
        if (mounted) {
          showGhostToast(
            context,
            msg,
            icon: Icons.error,
            type: GhostToastType.error,
          );
        }
      },
    );
  }

  Widget _buildAttachmentClearButton({required String tooltip}) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: GhostColors.surfaceAlpha85,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GhostColors.glassBorder),
      ),
      child: IconButton(
        onPressed: _clearPendingAttachmentPreview,
        icon: const Icon(Icons.close_rounded, size: 14),
        color: GhostColors.textMuted,
        tooltip: tooltip,
        splashRadius: 14,
        padding: EdgeInsets.zero,
      ),
    );
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();

    try {
      final initialUri = await appLinks.getInitialLink();
      if (initialUri != null) {
        unawaited(_handleDeepLink(initialUri));
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Error getting initial link: $e');
    }

    _linkSubscription = appLinks.uriLinkStream.listen(
      _handleDeepLink,
      onError: (Object err) {
        debugPrint('[MobileMain] Link stream error: $err');
      },
    );
  }

  Future<void> _handleDeepLink(Uri uri) async {
    debugPrint('[MobileMain] Deep link received: $uri');
    if (uri.scheme == 'ghostcopy' && uri.host == 'share') {
      final clipboardId = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.first
          : null;
      if (clipboardId != null) {
        await _viewModel.processShareAction(clipboardId, action: 'share');
      }
    }
  }

  void _setupMethodChannels() {
    _shareChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'handleShareIntent':
          // ignore: avoid_dynamic_calls
          final content = call.arguments['content'] as String?;
          if (content != null && content.isNotEmpty) {
            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              content,
            );

            if (selectedDeviceTypes != null) {
              unawaited(
                _viewModel.saveSharedContent(
                  content,
                  selectedDeviceTypes,
                  onSuccess: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: GhostColors.success,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  onError: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: Colors.red.shade400,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              );
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
            if (imageBytes.length > 10 * 1024 * 1024) {
              debugPrint(
                '[MobileMain] Image too large: ${imageBytes.length} bytes',
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

            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              'Image ($sizeKB KB)',
            );

            if (selectedDeviceTypes != null) {
              unawaited(
                _viewModel.saveSharedImage(
                  imageBytes,
                  mimeType!,
                  selectedDeviceTypes,
                  onSuccess: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: GhostColors.success,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  onError: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: Colors.red.shade400,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
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
            if (fileBytes.length > 10 * 1024 * 1024) {
              debugPrint(
                '[MobileMain] File too large: ${fileBytes.length} bytes',
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

            final selectedDeviceTypes = await _showDeviceSelectorDialog(
              '$filename ($sizeKB KB)',
            );

            if (selectedDeviceTypes != null) {
              unawaited(
                _viewModel.saveSharedFile(
                  fileBytes,
                  mimeType!,
                  filename,
                  selectedDeviceTypes,
                  onSuccess: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: GhostColors.success,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  onError: (msg) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          backgroundColor: Colors.red.shade400,
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              );
            }
            return true;
          }
          return false;

        default:
          return false;
      }
    });

    _notificationChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'handleNotificationAction':
          // ignore: avoid_dynamic_calls
          final clipboardId = call.arguments['clipboardId'] as String?;
          // ignore: avoid_dynamic_calls
          final action = call.arguments['action'] as String?;
          return _viewModel.handleNotificationAction(
            clipboardId: clipboardId,
            action: action,
          );

        default:
          return false;
      }
    });
  }

  void _initializeShareIntentListeners() {
    ReceiveSharingIntent.instance.getInitialMedia().then((value) {
      if (value.isNotEmpty) {
        _viewModel.handleSharedFiles(
          value,
          onSuccess: (msg) {
            if (mounted) {
              showGhostToast(
                context,
                msg,
                icon: Icons.upload_file,
                type: GhostToastType.success,
              );
            }
          },
        );
      }
    });

    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(
          (value) {
            if (value.isNotEmpty) {
              _viewModel.handleSharedFiles(
                value,
                onSuccess: (msg) {
                  if (mounted) {
                    showGhostToast(
                      context,
                      msg,
                      icon: Icons.upload_file,
                      type: GhostToastType.success,
                    );
                  }
                },
              );
            }
          },
          onError: (Object err) {
            debugPrint('getMediaStream error: $err');
          },
        );

    debugPrint('[ShareSheet] Share intent listeners initialized');
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
              ? GhostColors.primaryAlpha20
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

  Future<void> _handleSend() async {
    // Check if sending image or text
    if (_viewModel.clipboardContent?.hasImage ?? false) {
      await _viewModel.handleSend(
        _pasteController.text,
        onSendSuccess: () {
          Adaptive.successFeedback();
          if (mounted) {
            _pasteController.clear();
            showGhostToast(
              context,
              'Image sent successfully',
              icon: Icons.image,
              type: GhostToastType.success,
            );
          }
        },
      );
      return;
    }

    final content = _pasteController.text.trim();
    if (content.isEmpty) {
      _viewModel.setSendError('Please paste or type content to send');
      return;
    }

    // Security check
    final isSensitive = await _viewModel.checkSensitiveData(content);
    if (isSensitive) {
      final shouldContinue = await _showSensitiveDataWarning();
      if (!shouldContinue) return;
    }

    await _viewModel.handleSend(
      _pasteController.text,
      onSendSuccess: () {
        Adaptive.successFeedback();
        if (mounted) {
          _pasteController.clear();
          showGhostToast(
            context,
            'Sent successfully',
            icon: Icons.send,
            type: GhostToastType.success,
          );
        }
      },
    );
  }

  /// Bounds to anchor the iPad share popover to.
  ///
  /// UIKit throws if UIActivityViewController is presented on iPad without a
  /// source rect. The screen's own bounds are a safe anchor - the sheet is
  /// reached from a list row, and pointing at the row would require plumbing a
  /// RenderBox per item for no visible gain.
  Rect? _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<bool> _showSensitiveDataWarning() async {
    return Adaptive.confirm(
      context,
      title: 'Sensitive Data Detected',
      message:
          'This content may contain sensitive information (passwords, API keys, etc.). Are you sure you want to sync it?',
      confirmText: 'Send Anyway',
      icon: Icons.warning_amber_rounded,
      confirmColor: Colors.orange.shade400,
    );
  }

  Future<void> _navigateToSettings() async {
    final authService = locator<IAuthService>();
    final userBefore = authService.currentUserId;

    await Navigator.of(context).push(
      Adaptive.pageRoute<void>(
        builder: (context) => MobileSettingsScreen(
          authService: locator(),
          deviceService: locator(),
          settingsService: locator(),
        ),
      ),
    );

    if (!mounted) return;

    // Signing out swaps in a fresh anonymous account. Clearing only the two
    // derived caches left the previous user's clips on screen and in memory
    // until a load replaced them, so drop the whole per-user state instead.
    if (authService.currentUserId != userBefore) {
      debugPrint('[MobileMain] Account changed - clearing user state');
      _viewModel.clearUserState();
    } else {
      // Same account: encryption keys may have changed, so caches are stale.
      _viewModel.clearCaches();
    }

    await _viewModel.loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GhostColors.background,
      appBar: AppBar(
        // Same colour as the body: see AppTheme.appBarTheme for why.
        backgroundColor: GhostColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        // AppBar derives its own overlay style from the background colour,
        // which would undo the transparent status bar set in main(). Pin it so
        // the header's colour shows through the cutout strip with light
        // glyphs over it.
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        toolbarHeight: 62,
        titleSpacing: GhostSpacing.gutter,
        title: Row(
          children: [
            // The mark sits in an accent tile rather than floating loose, so
            // the header has one solid anchor at 30px instead of a 28px image
            // competing with the wordmark beside it.
            Container(
              width: 30,
              height: 30,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: GhostColors.primary,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Image.asset(
                'assets/icons/logo_white.png',
                color: Colors.white,
                errorBuilder: (context, error, stack) => const Icon(
                  Icons.content_copy_rounded,
                  size: 17,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'GhostCopy',
              style: GhostTypography.headline.copyWith(
                fontSize: 17,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _navigateToSettings,
            color: GhostColors.textMuted,
            tooltip: 'Settings',
          ),
          // The logo on the left is a solid 30px tile whose edge sits exactly
          // on the 16dp gutter. The settings glyph is centred in a 48px
          // IconButton, so it carries 12dp of box padding plus ~3dp of glyph
          // bearing - 1dp of trailing gap is what puts its VISIBLE edge on 16
          // too. Anything larger pushed the header's right margin past every
          // card below it and tipped the page's axis left.
          const SizedBox(width: 1),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _viewModel.handleRefresh,
        color: GhostColors.primary,
        backgroundColor: GhostColors.surface,
        // Sit the spinner above the composer instead of on top of it. At the
        // default displacement its circular backdrop overlaps the composer's
        // top edge, which reads as a stray disc behind the card.
        displacement: 16,
        child: CustomScrollView(
          physics: Adaptive.scrollPhysics,
          slivers: [
            SliverPadding(
              // One padded column for the whole page, so the composer, chips,
              // button and history share a single left edge. Bottom clears the
              // gesture bar, since the app draws edge-to-edge.
              padding: EdgeInsets.fromLTRB(
                GhostSpacing.gutter,
                8,
                GhostSpacing.gutter,
                24 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              sliver: SliverList.list(
                children: [
                  _buildPasteArea(),
                  const SizedBox(height: 15),
                  _buildDeviceSelector(),
                  const SizedBox(height: 13),
                  _buildSendButton(),
                  const SizedBox(height: GhostSpacing.sectionLoose),
                  _buildLockedClipsBanner(),
                  _buildHistorySection(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Build image preview for paste area (when clipboard contains image)
  Widget _buildImagePreview() {
    if (_viewModel.clipboardContent?.hasImage != true ||
        _viewModel.clipboardContent?.imageBytes == null) {
      return const SizedBox.shrink();
    }

    final imageBytes = _viewModel.clipboardContent!.imageBytes!;
    final mimeType = _viewModel.clipboardContent!.mimeType ?? 'unknown';
    final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GhostColors.primaryAlpha30),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Image ready to send',
                  style: GhostTypography.caption.copyWith(
                    color: GhostColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
              _buildAttachmentClearButton(tooltip: 'Remove image'),
            ],
          ),
          const SizedBox(height: 8),
          // Perf: Container with clipBehavior instead of ClipRRect to
          // avoid saveLayer on raster thread
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 80),
              child: Image.memory(
                imageBytes,
                fit: BoxFit.contain,
                cacheHeight:
                    (80 *
                            MediaQuery.devicePixelRatioOf(
                              context,
                            ).clamp(1.0, 2.0))
                        .round(),
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

  Widget _buildFilePreview() {
    final content = _viewModel.clipboardContent;
    if (content?.hasFile != true || content?.fileBytes == null) {
      return const SizedBox.shrink();
    }

    final filename = content!.filename ?? 'file';
    final sizeKB = (content.fileBytes!.length / 1024).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: GhostColors.primaryAlpha30),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.insert_drive_file_rounded,
            size: 24,
            color: GhostColors.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GhostTypography.body.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$sizeKB KB',
                  style: GhostTypography.caption.copyWith(
                    color: GhostColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _buildAttachmentClearButton(tooltip: 'Remove file'),
        ],
      ),
    );
  }

  /// The composer: one surface holding the text field, any staged
  /// attachment, and the attach control.
  ///
  /// Previously a card containing a separately-bordered text field, which read
  /// as a card inside a card, under a "Paste & Send" heading that only
  /// restated the placeholder below it. The heading is gone and the field is
  /// borderless in every state - including focus, which inherited a 2px
  /// primary outline from the theme and lit the whole box up bright purple.
  /// Focus is now shown by the surface border alone.
  /// The composer: one surface holding the text field, any staged
  /// attachment, and a toolbar.
  ///
  /// Previously a card containing a separately-bordered text field - a card
  /// inside a card - under a "Paste & Send" heading that only restated the
  /// placeholder below it. The field is borderless in EVERY state: setting
  /// only `border` left focusedBorder falling back to the theme's 2px primary
  /// outline, which lit the whole box up on focus.
  Widget _buildPasteArea() {
    final hasAttachment =
        (_viewModel.clipboardContent?.hasFile ?? false) ||
        (_viewModel.clipboardContent?.hasImage ?? false);

    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: GhostColors.surface,
          borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
          border: Border.all(
            color: _composerFocused
                ? GhostColors.accentBorder
                : GhostColors.border,
          ),
          // No drop shadow. The handoff carries one (0 8px 28px at 19% black),
          // which reads as elevation on its light mock - but on a near-black
          // background a black shadow can only darken, so it renders as a soft
          // dark halo around the card that looks like a gradient or a patch of
          // a different background colour rather than depth. The border does
          // the separating instead.
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasAttachment) ...[
              const SizedBox(height: GhostSpacing.sectionTight),
              if (_viewModel.clipboardContent?.hasFile ?? false)
                _buildFilePreview(),
              if (_viewModel.clipboardContent?.hasImage ?? false)
                _buildImagePreview(),
            ],
            TextField(
              controller: _pasteController,
              focusNode: _pasteFocusNode,
              // minLines sets the empty composer's height directly. Expanded
              // cannot: this lives in a sliver, so incoming height is
              // unbounded and a flex child has nothing to expand into.
              minLines: 3,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontSize: 16,
                color: GhostColors.textPrimary,
              ),
              decoration: const InputDecoration(
                hintText: 'Paste or type something…',
                hintStyle: TextStyle(color: GhostColors.textMuted),
                contentPadding: EdgeInsets.fromLTRB(16, 16, 16, 10),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
              ),
              onChanged: (value) {
                if (_sendError.value != null) {
                  _viewModel.clearSendError();
                }
                // The toolbar shows whether there is anything to send.
                setState(() {});
              },
            ),
            const Divider(height: 1, color: GhostColors.border),
            _buildComposerToolbar(hasAttachment: hasAttachment),
            ValueListenableBuilder<String?>(
              valueListenable: _sendError,
              builder: (context, error, _) {
                if (error == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    GhostSpacing.gutter,
                    0,
                    GhostSpacing.gutter,
                    GhostSpacing.sectionTight,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 15,
                        color: GhostColors.errorLight,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          error,
                          style: const TextStyle(
                            fontSize: 12,
                            color: GhostColors.errorLight,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Bottom toolbar of the composer.
  ///
  /// The attach control lives inside the surface it acts on rather than
  /// floating below it, and one control covers both images and files - they
  /// were once separate buttons in different places that behaved differently,
  /// which made the distinction feel arbitrary.
  Widget _buildComposerToolbar({required bool hasAttachment}) {
    final hasContent = _pasteController.text.trim().isNotEmpty || hasAttachment;

    return Padding(
      // 14 here plus Material's 2dp inset inside a zero-padding
      // TextButton.icon puts the Attach glyph at 16dp - the same left edge as
      // the text above it and the history rows below. Measured from rendered
      // pixels rather than derived, because the button's internal geometry is
      // not obvious from its API.
      padding: const EdgeInsets.fromLTRB(14, 4, 12, 5),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _showAttachSheet,
            icon: const Icon(Icons.attach_file_rounded, size: 17),
            label: const Text('Attach'),
            style: TextButton.styleFrom(
              minimumSize: const Size(GhostSpacing.minTouchTarget, 40),
              padding: EdgeInsets.zero,
              foregroundColor: GhostColors.textMuted,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(GhostSpacing.thumbRadius),
              ),
            ),
          ),
          const Spacer(),
          // Flexible so a long status never pushes the Attach button off the
          // toolbar on a narrow screen.
          Flexible(
            child: Text(
              hasContent ? 'Ready to send' : 'Nothing to send yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: GhostColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSelector() {
    final targets = _viewModel.deviceTypeTargets;

    // No "Send to" caption and no platform count above the row. The chips name
    // the destinations and the button restates the choice, so both were
    // labelling something already legible.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: GhostSpacing.chipHeight,
          child: _viewModel.devicesLoading
              ? Center(
                  child: Adaptive.progressIndicator(
                    size: 18,
                    color: GhostColors.primary,
                  ),
                )
              : _viewModel.deviceError != null
              ? _buildDeviceError()
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  physics: Adaptive.scrollPhysics,
                  itemCount: targets.length + 1,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _DeviceChip(
                        label: 'All devices',
                        icon: Icons.devices_rounded,
                        isSelected: _viewModel.selectedDeviceTypes.isEmpty,
                        onTap: _viewModel.clearDeviceTypeSelection,
                      );
                    }

                    // One chip per device TYPE, not per device: the backend
                    // routes on target_device_type (a platform enum array) and
                    // cannot address an individual machine. A chip per device
                    // made two Windows PCs highlight together on one tap.
                    final target = targets[index - 1];
                    return _DeviceChip(
                      label: target.label,
                      tooltip: 'Sends to ${target.deviceNames}',
                      icon: _getDeviceIcon(target.deviceType),
                      isSelected: _viewModel.selectedDeviceTypes.contains(
                        target.deviceType,
                      ),
                      onTap: () =>
                          _viewModel.toggleDeviceType(target.deviceType),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDeviceError() {
    return GestureDetector(
      onTap: () => _viewModel.loadDevices(forceRefresh: true),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline,
            size: 14,
            color: GhostColors.errorLight,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _viewModel.deviceError ?? 'Could not load devices',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GhostTypography.caption.copyWith(
                color: GhostColors.textMuted,
              ),
            ),
          ),
          const Icon(Icons.refresh, size: 14, color: GhostColors.primary),
        ],
      ),
    );
  }

  Widget _buildSendButton() {
    return SizedBox(
      width: double.infinity,
      // Taller than the 38px chips above it. The size difference marks this as
      // the primary action, now that it is the only saturated accent on the
      // screen.
      height: GhostSpacing.sendButtonHeight,
      child: FilledButton.icon(
        onPressed: _viewModel.isSending ? null : _handleSend,
        icon: _viewModel.isSending
            ? Adaptive.progressIndicator(size: 18, color: Colors.white)
            : const Icon(Icons.send_rounded, size: 18),
        label: Text(_viewModel.isSending ? 'Sending…' : _sendButtonLabel()),
        style: FilledButton.styleFrom(
          backgroundColor: GhostColors.primary,
          disabledBackgroundColor: GhostColors.accentDisabled,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GhostSpacing.buttonRadius),
          ),
        ),
      ),
    );
  }

  /// Label for the send button, naming the destination the chips selected.
  ///
  /// Counting "Devices" was wrong for the same reason the chips were: a
  /// selection is a platform, and one platform can cover several machines, so
  /// "Send to 1 Device" was a miscount whenever a type had more than one.
  String _sendButtonLabel() {
    final selected = _viewModel.selectedDeviceTypes;
    if (selected.isEmpty) return 'Send to all devices';
    if (selected.length == 1) {
      return 'Send to ${DeviceTypeTarget.platformLabel(selected.first)}';
    }
    return 'Send to ${selected.length} platforms';
  }

  /// Banner shown whenever this device holds clips it cannot decrypt.
  ///
  /// Rendered above the history list rather than inside its empty state: the
  /// locked clips are removed from the list, so if anything readable exists
  /// the list is non-empty and an empty-state message would never appear.
  Widget _buildLockedClipsBanner() {
    return ValueListenableBuilder<int>(
      valueListenable: _viewModel.undecryptableItemCount,
      builder: (context, locked, _) {
        if (locked == 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: GhostSpacing.sectionTight),
          child: Material(
            color: GhostColors.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
            child: InkWell(
              borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
              onTap: _navigateToSettings,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      color: GhostColors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            locked == 1
                                ? '1 clip is encrypted'
                                : '$locked clips are encrypted',
                            style: GhostTypography.body.copyWith(
                              color: GhostColors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Tap to enter your passphrase. It is never sent '
                            'to the server, so each device needs it once.',
                            style: GhostTypography.caption.copyWith(
                              color: GhostColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right,
                      color: GhostColors.textMuted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// History: heading, always-visible search, then one grouped list.
  ///
  /// Rows were individually floating cards, which cost a margin and a border
  /// each and made fifteen clips read as fifteen separate objects. One
  /// container with hairline dividers reads as a single list and fits far more
  /// on screen.
  Widget _buildHistorySection() {
    final items = _viewModel.filteredHistoryItems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'Clipboard history',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GhostTypography.headline.copyWith(fontSize: 15),
              ),
            ),
            const SizedBox(width: 7),
            Text(
              '${items.length} recent',
              style: GhostTypography.caption.copyWith(
                color: GhostColors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _buildHistorySearch(),
        const SizedBox(height: GhostSpacing.sectionTight),
        if (_viewModel.historyLoading)
          SizedBox(
            height: 120,
            child: Center(
              child: Adaptive.progressIndicator(
                size: 28,
                color: GhostColors.primary,
              ),
            ),
          )
        else if (_viewModel.historyError != null)
          _buildHistoryMessage(
            icon: Icons.error_outline_rounded,
            message: _viewModel.historyError!,
          )
        else if (items.isEmpty)
          _buildHistoryMessage(
            icon: Icons.content_paste_off_outlined,
            message: _viewModel.historySearchQuery.isNotEmpty
                ? 'No clips match your search'
                : 'Nothing here yet. Send something to get started.',
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: GhostColors.surface,
              borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
              border: Border.all(color: GhostColors.border),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                GhostSpacing.surfaceRadiusInner,
              ),
              child: Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    if (index > 0)
                      const Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: GhostColors.border,
                      ),
                    _buildHistoryRow(items[index]),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHistorySearch() {
    return TextField(
      controller: _historySearchController,
      onChanged: _viewModel.filterHistoryDebounced,
      style: const TextStyle(fontSize: 16, color: GhostColors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Search clips…',
        hintStyle: const TextStyle(color: GhostColors.textMuted),
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 18,
          color: GhostColors.textMuted,
        ),
        suffixIcon: _viewModel.historySearchQuery.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, size: 17),
                color: GhostColors.textMuted,
                tooltip: 'Clear search',
                onPressed: () {
                  _historySearchController.clear();
                  _viewModel.filterHistory('');
                },
              ),
        filled: true,
        fillColor: GhostColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GhostSpacing.controlRadius),
          borderSide: const BorderSide(color: GhostColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GhostSpacing.controlRadius),
          borderSide: const BorderSide(color: GhostColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GhostSpacing.controlRadius),
          borderSide: const BorderSide(color: GhostColors.accentBorder),
        ),
      ),
    );
  }

  Widget _buildHistoryMessage({
    required IconData icon,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(GhostSpacing.surfaceRadius),
        border: Border.all(color: GhostColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, color: GhostColors.textMuted),
          const SizedBox(height: 9),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GhostTypography.caption.copyWith(
              fontSize: 13,
              color: GhostColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryRow(ClipboardItem item) {
    return Dismissible(
      // Keyed on the clip id, not the index, so the correct row is removed
      // when the list shifts under a realtime update.
      key: ValueKey<String>('dismiss-${item.id}'),
      // Left only. A right swipe is left free for a future action, and one
      // direction makes an accidental delete less likely on a list the user
      // scrolls constantly.
      direction: DismissDirection.endToStart,
      background: _buildDeleteBackground(),
      confirmDismiss: (_) => _confirmDeleteClip(item),
      onDismissed: (_) => _deleteClip(item),
      child: RepaintBoundary(
        key: ValueKey<String>(item.id),
        child: _HistoryRow(
          item: item,
          transformerService: _transformerService,
          clipboardRepository: _clipboardRepository,
          encryptionService: _viewModel.encryptionService,
          cachedDecryptedContent: _viewModel.decryptedContentCache[item.id],
          cachedDetectionResult: _viewModel.detectionCache[item.id],
          onContentDecrypted: (content) =>
              _viewModel.cacheDecryptedContent(item.id, content),
          onContentDetected: (result) =>
              _viewModel.cacheDetectionResult(item.id, result),
          onTap: () => _copyClip(item),
          onCopy: () => _copyClip(item),
        ),
      ),
    );
  }

  /// Copy a clip to the clipboard, with platform-appropriate confirmation.
  void _copyClip(ClipboardItem item) {
    unawaited(
      _viewModel.handleHistoryItemTap(
        item,
        sharePositionOrigin: _shareOrigin(),
        onSuccess: (msg) {
          // iOS has no system toast, so the tick IS the confirmation there -
          // fire it before the mounted check.
          Adaptive.successFeedback();
          if (mounted) {
            unawaited(showNativeToast(context, msg, icon: Icons.copy));
          }
        },
        onError: (msg) {
          if (mounted) {
            showGhostToast(
              context,
              msg,
              icon: Icons.error,
              type: GhostToastType.error,
            );
          }
        },
      ),
    );
  }

  /// Red panel revealed behind a row being swiped away.
  Widget _buildDeleteBackground() {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: GhostSpacing.gutter,
        vertical: 6,
      ),
      padding: const EdgeInsets.only(right: 24),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: Colors.red.shade400,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
    );
  }

  /// Confirm before deleting.
  ///
  /// Deliberately not a silent swipe-to-delete: this removes the clip from the
  /// server, so it vanishes from every signed-in device, not just this phone.
  /// That is not something to do on an accidental gesture mid-scroll.
  Future<bool> _confirmDeleteClip(ClipboardItem item) async {
    Adaptive.impactFeedback();
    if (!mounted) return false;
    return Adaptive.confirm(
      context,
      title: 'Delete clip?',
      message:
          'This removes it from all your devices, not just this one. It cannot be undone.',
      confirmText: 'Delete',
      isDestructive: true,
    );
  }

  Future<void> _deleteClip(ClipboardItem item) async {
    await _viewModel.handleHistoryItemDelete(
      item,
      onSuccess: (msg) {
        if (mounted) {
          unawaited(showNativeToast(context, msg, icon: Icons.delete_outline));
        }
      },
      onError: (msg) {
        if (mounted) {
          showGhostToast(
            context,
            msg,
            icon: Icons.error,
            type: GhostToastType.error,
          );
        }
      },
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
/// Destination chip: one platform, or "All devices".
class _DeviceChip extends StatelessWidget {
  const _DeviceChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.tooltip,
  });

  static const _radius = BorderRadius.all(
    Radius.circular(GhostSpacing.chipRadius),
  );

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  /// Long-press reveals the actual machines behind a platform, since the chip
  /// deliberately names the platform rather than any one device.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Semantics(
      selected: isSelected,
      button: true,
      child: Material(
        // A tint, not a fill. A solid accent chip competed with the Send
        // button, and several selected turned the row into a block that read
        // as the loudest thing on screen - which a destination picker is not.
        color: isSelected ? GhostColors.accentSoft : GhostColors.surface,
        borderRadius: _radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: _radius,
          child: Container(
            height: GhostSpacing.chipHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: _radius,
              border: Border.all(
                color: isSelected
                    ? GhostColors.accentBorder
                    : GhostColors.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: isSelected
                      ? GhostColors.accentText
                      : GhostColors.textMuted,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isSelected
                        ? GhostColors.accentText
                        : GhostColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final message = tooltip;
    return message == null ? chip : Tooltip(message: message, child: chip);
  }
}

/// History item with smart transformer detection and preview mode.
/// One row in the grouped history list.
///
/// Replaces the old floating card, which gave every clip a margin, a border
/// and a full-width 120px image preview - two screenshots filled the screen
/// and pushed everything else below the fold. A row is a 52px thumbnail, two
/// lines of preview, one metadata line and a copy button.
///
/// Still stateful for the same reason the card was: content-type detection is
/// async, and its result is cached in the ViewModel so scrolling does not
/// re-run it.
class _HistoryRow extends StatefulWidget {
  const _HistoryRow({
    required this.item,
    required this.transformerService,
    required this.clipboardRepository,
    required this.onTap,
    required this.onCopy,
    this.encryptionService,
    this.cachedDecryptedContent,
    this.cachedDetectionResult,
    this.onContentDecrypted,
    this.onContentDetected,
  });

  final ClipboardItem item;
  final ITransformerService transformerService;
  final IClipboardRepository clipboardRepository;
  final EncryptionService? encryptionService;
  final String? cachedDecryptedContent;
  final ContentDetectionResult? cachedDetectionResult;
  final ValueChanged<String>? onContentDecrypted;
  final ValueChanged<ContentDetectionResult>? onContentDetected;
  final VoidCallback onTap;
  final VoidCallback onCopy;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  ContentDetectionResult? _detectionResult;

  @override
  void initState() {
    super.initState();
    unawaited(_detectContentType());
  }

  @override
  void didUpdateWidget(_HistoryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.content != oldWidget.item.content) {
      unawaited(_detectContentType());
    }
  }

  Future<void> _detectContentType() async {
    if (widget.cachedDetectionResult != null) {
      _detectionResult = widget.cachedDetectionResult;
      return;
    }
    // Content is already plaintext: getHistory()/watchHistory() run
    // _decryptItems() before items reach the UI. isEncrypted is kept as
    // metadata (the home-screen widget uses it to suppress previews), so it
    // must not be used to trigger a second decrypt here.
    final result = await widget.transformerService.detectContentType(
      widget.item.content,
    );
    if (!mounted) return;
    widget.onContentDetected?.call(result);
    setState(() => _detectionResult = result);
  }

  /// What the row shows as its preview line.
  String get _previewText {
    final item = widget.item;
    if (item.isImage) {
      return item.metadata?.originalFilename ?? 'Image';
    }
    if (item.isFile) {
      return item.metadata?.originalFilename ?? 'File';
    }
    // Collapse whitespace so a multi-line clip does not waste both lines on
    // indentation.
    return item.content.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final hasLeading = item.isImage || item.isFile;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        // Long-press opens the full clip with its smart actions (JSON
        // prettify, JWT decode). Those used to render inline in the expanded
        // card; a compact row has no space for them, so they move to a sheet
        // rather than being dropped.
        onLongPress: () => _showDetail(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: GhostSpacing.historyRowMinHeight,
          ),
          child: Padding(
            // 16dp left, matching the composer's text inset, so every card
            // on the page shares one left edge. It was 12, which put history
            // rows 4dp to the left of everything above them and made the whole
            // stack look off-centre even though the cards are exactly centred.
            // Right is 3 so the 18px icon inside its 44px touch target lands
            // its visual edge at 16 too.
            padding: const EdgeInsets.fromLTRB(16, 10, 3, 10),
            child: Row(
              children: [
                if (hasLeading) ...[_buildLeading(), const SizedBox(width: 11)],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _previewText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 7),
                      _buildMetaLine(),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: widget.onCopy,
                  tooltip: 'Copy clip',
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  color: GhostColors.textMuted,
                  constraints: const BoxConstraints(
                    minWidth: GhostSpacing.minTouchTarget,
                    minHeight: GhostSpacing.minTouchTarget,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Thumbnail for an image, or a typed icon tile for a file.
  Widget _buildLeading() {
    final item = widget.item;

    return Container(
      width: GhostSpacing.thumbSize,
      height: GhostSpacing.thumbSize,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(GhostSpacing.thumbRadius),
      ),
      child: item.isImage
          ? CachedClipboardImage(
              item: item,
              clipboardRepository: widget.clipboardRepository,
              width: GhostSpacing.thumbSize,
              height: GhostSpacing.thumbSize,
            )
          : Icon(_fileIcon(item), color: GhostColors.accentText, size: 23),
    );
  }

  /// Icon for a file row, by type rather than one generic page glyph.
  ///
  /// FileTypeService already maps ContentType to an icon (PDF, doc, txt, zip,
  /// audio, video) - the row was ignoring it and drawing the same sheet of
  /// paper for everything. Falls back to the filename extension when the row
  /// was stored before type detection, or came in as fileOther.
  static IconData _fileIcon(ClipboardItem item) {
    final service = FileTypeService.instance;

    if (item.contentType != ContentType.fileOther) {
      return service.getFileIcon(item.contentType);
    }

    final filename = item.metadata?.originalFilename;
    if (filename != null && filename.contains('.')) {
      return service.getFileIcon(
        service.detectFromExtension(filename).contentType,
      );
    }
    return Icons.insert_drive_file;
  }

  /// `source • time → destination`, one compact line.
  Widget _buildMetaLine() {
    final item = widget.item;

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 5,
      runSpacing: 3,
      children: [
        Icon(
          _iconForDeviceType(item.deviceType),
          size: 12,
          color: GhostColors.textMuted,
        ),
        Text(
          DeviceTypeTarget.platformLabel(item.deviceType),
          style: const TextStyle(fontSize: 11, color: GhostColors.textMuted),
        ),
        const Text(
          '•',
          style: TextStyle(fontSize: 11, color: GhostColors.textMuted),
        ),
        Text(
          timeago.format(item.createdAt, locale: 'en_short'),
          style: const TextStyle(fontSize: 11, color: GhostColors.textMuted),
        ),
        const Text(
          '→',
          style: TextStyle(fontSize: 11, color: GhostColors.textMuted),
        ),
        Text(
          // Always stated, including "All devices". The old UI showed a
          // generic icon only when a clip WAS targeted, so absence had to mean
          // "went everywhere" - which no missing icon can communicate.
          _targetLabel(item.targetDeviceTypes),
          style: const TextStyle(fontSize: 11, color: GhostColors.accentText),
        ),
      ],
    );
  }

  static IconData _iconForDeviceType(String deviceType) =>
      switch (deviceType.toLowerCase()) {
        'windows' => Icons.laptop_windows,
        'macos' => Icons.laptop_mac,
        'linux' => Icons.laptop_chromebook,
        'android' => Icons.phone_android,
        'ios' => Icons.phone_iphone,
        _ => Icons.devices,
      };

  static String _targetLabel(List<String>? targets) {
    if (targets == null || targets.isEmpty) return 'All devices';
    if (targets.length == 1) {
      return DeviceTypeTarget.platformLabel(targets.first);
    }
    if (targets.length == 2) {
      return targets.map(DeviceTypeTarget.platformLabel).join(', ');
    }
    return '${targets.length} devices';
  }

  /// Full clip in a sheet: the whole content, plus the smart actions that no
  /// longer fit in a row.
  void _showDetail(BuildContext context) {
    Adaptive.impactFeedback();
    final detection = _detectionResult;

    unawaited(
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: GhostColors.surface,
        showDragHandle: true,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(GhostSpacing.surfaceRadius),
          ),
        ),
        builder: (sheetContext) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              GhostSpacing.gutter,
              0,
              GhostSpacing.gutter,
              GhostSpacing.gutter,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.item.isImage)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        GhostSpacing.thumbRadius,
                      ),
                      child: CachedClipboardImage(
                        item: widget.item,
                        clipboardRepository: widget.clipboardRepository,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      physics: Adaptive.scrollPhysics,
                      child: SelectableText(
                        widget.item.content,
                        style: const TextStyle(
                          fontSize: 14,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                if (detection != null) ...[
                  const SizedBox(height: GhostSpacing.sectionTight),
                  SmartActionButtons(
                    content: widget.item.content,
                    detectionResult: detection,
                    transformerService: widget.transformerService,
                  ),
                ],
                const SizedBox(height: GhostSpacing.sectionTight),
                SizedBox(
                  width: double.infinity,
                  height: GhostSpacing.sendButtonHeight,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      widget.onCopy();
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy'),
                    style: FilledButton.styleFrom(
                      backgroundColor: GhostColors.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          GhostSpacing.buttonRadius,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
