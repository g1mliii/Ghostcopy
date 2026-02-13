import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../locator.dart';
import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/transformer_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../viewmodels/mobile_main_viewmodel.dart';
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
  const MobileMainScreen({super.key});

  @override
  State<MobileMainScreen> createState() => _MobileMainScreenState();
}

class _MobileMainScreenState extends State<MobileMainScreen>
    with WidgetsBindingObserver {
  late final MobileMainViewModel _viewModel;
  bool _isRebuildScheduled = false;

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

    _viewModel =
        MobileMainViewModel(
            authService: locator(),
            clipboardRepository: locator(),
            deviceService: locator(),
            securityService: locator(),
            settingsService: locator(),
          )
          ..addListener(_onViewModelChanged)
          ..initialize();

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

  Future<void> _handleSend() async {
    // Check if sending image or text
    if (_viewModel.clipboardContent?.hasImage ?? false) {
      await _viewModel.handleSend(
        _pasteController.text,
        onSendSuccess: () {
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

  Future<void> _navigateToSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MobileSettingsScreen(
          authService: locator(),
          deviceService: locator(),
          settingsService: locator(),
        ),
      ),
    );

    // Refresh history when returning from settings (encryption keys may have changed)
    if (mounted) {
      _viewModel.clearCaches();
      await _viewModel.loadHistory();
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
            tooltip: 'Settings',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _viewModel.handleFilePick(
          onLargeFileConfirm: (sizeMB) async {
            if (!mounted) return false;
            final shouldContinue =
                await showDialog<bool>(
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
                ) ??
                false;
            return shouldContinue;
          },
          onSuccess: (filename) {
            if (mounted) {
              showGhostToast(
                context,
                'File uploaded: $filename',
                icon: Icons.upload_file,
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
        ),
        backgroundColor: GhostColors.primary,
        tooltip: 'Attach file',
        child: const Icon(Icons.attach_file, color: Colors.white),
      ),
      body: RefreshIndicator(
        onRefresh: _viewModel.handleRefresh,
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
                  onChanged: _viewModel.filterHistoryDebounced,
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
                    suffixIcon: _viewModel.historySearchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _historySearchController.clear();
                              _viewModel.filterHistory('');
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
        border: Border.all(color: GhostColors.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
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
    return RepaintBoundary(
      child: Container(
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
            if (_viewModel.clipboardContent?.hasImage ?? false)
              _buildImagePreview(),
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
                  if (_sendError.value != null) {
                    _viewModel.clearSendError();
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _viewModel.handleImageUpload(
                      onSuccess: () {
                        if (mounted) {
                          showGhostToast(
                            context,
                            'Image uploaded successfully',
                            icon: Icons.check_circle,
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
                    ),
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
            ValueListenableBuilder<String?>(
              valueListenable: _sendError,
              builder: (context, error, _) {
                if (error != null) {
                  return Padding(
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
                            error,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.red.shade400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return const SizedBox(height: 12);
              },
            ),
          ],
        ),
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
          child: _viewModel.devicesLoading
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
              : _viewModel.deviceError != null
              ? GestureDetector(
                  onTap: () => _viewModel.loadDevices(forceRefresh: true),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 14,
                          color: Colors.red[300],
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _viewModel.deviceError!,
                            style: TextStyle(
                              fontSize: 12,
                              color: GhostColors.textMuted,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.refresh,
                          size: 14,
                          color: GhostColors.primary,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _viewModel.devices.length + 1,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _DeviceChip(
                        label: 'All Devices',
                        icon: Icons.devices,
                        isSelected: _viewModel.selectedDeviceTypes.isEmpty,
                        onTap: () => _viewModel.clearDeviceTypeSelection(),
                      );
                    }

                    final device = _viewModel.devices[index - 1];
                    final isSelected = _viewModel.selectedDeviceTypes.contains(
                      device.deviceType,
                    );

                    return _DeviceChip(
                      label: device.displayName,
                      icon: _getDeviceIcon(device.deviceType),
                      isSelected: isSelected,
                      onTap: () =>
                          _viewModel.toggleDeviceType(device.deviceType),
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
          onPressed: _viewModel.isSending ? null : _handleSend,
          style: FilledButton.styleFrom(
            backgroundColor: GhostColors.primary,
            disabledBackgroundColor: GhostColors.primary.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          child: _viewModel.isSending
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
                      _viewModel.selectedDeviceTypes.isEmpty
                          ? 'Send to All Devices'
                          : 'Send to ${_viewModel.selectedDeviceTypes.length} Device${_viewModel.selectedDeviceTypes.length > 1 ? 's' : ''}',
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
    if (_viewModel.historyLoading) {
      return const SliverFillRemaining(
        child: Center(
          child: CircularProgressIndicator(color: GhostColors.primary),
        ),
      );
    }

    if (_viewModel.historyError != null) {
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text(
                _viewModel.historyError!,
                style: GhostTypography.body.copyWith(
                  color: GhostColors.textMuted,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_viewModel.filteredHistoryItems.isEmpty) {
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
                _viewModel.historySearchQuery.isNotEmpty
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
          final item = _viewModel.filteredHistoryItems[index];

          final cachedDecrypted = _viewModel.decryptedContentCache[item.id];
          final cachedDetection = _viewModel.detectionCache[item.id];

          return RepaintBoundary(
            child: _HistoryItemContent(
              key: ValueKey(item.id),
              item: item,
              transformerService: locator<ITransformerService>(),
              clipboardRepository: locator<IClipboardRepository>(),
              encryptionService: _viewModel.encryptionService,
              cachedDecryptedContent: cachedDecrypted,
              cachedDetectionResult: cachedDetection,
              onContentDecrypted: (content) {
                _viewModel.cacheDecryptedContent(item.id, content);
              },
              onContentDetected: (result) {
                _viewModel.cacheDetectionResult(item.id, result);
              },
              onTap: () => _viewModel.handleHistoryItemTap(
                item,
                onSuccess: (msg) {
                  if (mounted) {
                    showGhostToast(
                      context,
                      msg,
                      icon: Icons.copy,
                      type: GhostToastType.success,
                      duration: const Duration(seconds: 1),
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
              ),
            ),
          );
        }, childCount: _viewModel.filteredHistoryItems.length),
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

/// History item with smart transformer detection and preview mode.
/// Matches the desktop pattern — no per-item animation controllers.
///
/// Performance optimizations:
/// - Uses cached decrypted content to avoid re-decryption
/// - Uses cached detection results to avoid re-detection
/// - Stable ValueKey for efficient list updates
/// - RepaintBoundary wrapper prevents unnecessary repaints
class _HistoryItemContent extends StatefulWidget {
  const _HistoryItemContent({
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
  State<_HistoryItemContent> createState() => _HistoryItemContentState();
}

class _HistoryItemContentState extends State<_HistoryItemContent> {
  bool _isExpanded = false;

  ContentDetectionResult? _detectionResult;
  String? _decryptedContent;
  bool _isPreviewMode = false;

  @override
  void didUpdateWidget(_HistoryItemContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.content != oldWidget.item.content ||
        widget.cachedDecryptedContent != oldWidget.cachedDecryptedContent ||
        widget.encryptionService != oldWidget.encryptionService) {
      _initializeContentDetection();
    }
  }

  @override
  void initState() {
    super.initState();
    _initializeContentDetection();
  }

  Future<void> _initializeContentDetection() async {
    if (widget.cachedDecryptedContent != null) {
      _decryptedContent = widget.cachedDecryptedContent;

      if (widget.cachedDetectionResult != null) {
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

    var content = widget.item.content;
    if (_decryptedContent == null &&
        widget.encryptionService != null &&
        widget.item.isEncrypted) {
      try {
        content = await widget.encryptionService!.decrypt(content);
        _decryptedContent = content;

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

    if (_detectionResult == null) {
      final detectionResult = await widget.transformerService.detectContentType(
        _decryptedContent ?? content,
      );

      if (!mounted) return;

      _detectionResult = detectionResult;

      widget.onContentDetected?.call(detectionResult);

      _isPreviewMode =
          (detectionResult.type == TransformerContentType.json ||
              detectionResult.type == TransformerContentType.jwt) &&
          (_decryptedContent ?? content).length > 200;

      if (mounted) {
        setState(() {});
      }
    }
  }

  String _formatTimeAgo(DateTime timestamp) {
    return timeago.format(timestamp, locale: 'en_short');
  }

  String _getDeviceLabel(String deviceType) {
    return deviceType[0].toUpperCase() + deviceType.substring(1);
  }

  Widget _buildContentPreview(String displayContent) {
    if (widget.item.isImage) {
      return _buildImagePreview();
    }

    if (widget.item.isFile) {
      return _buildFilePreview();
    }

    if (widget.item.isRichText) {
      return _buildRichTextPreview(displayContent);
    }

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

  Widget _buildImagePreview() {
    return CachedClipboardImage(
      item: widget.item,
      clipboardRepository: widget.clipboardRepository,
      height: 120,
      width: double.infinity,
    );
  }

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

  Widget _buildRichTextPreview(String content) {
    final format = widget.item.richTextFormat;
    final icon = format == RichTextFormat.html ? Icons.code : Icons.text_fields;
    final label = format == RichTextFormat.html ? 'HTML' : 'Markdown';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

    return Material(
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
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                        _buildContentPreview(displayContent),
                      ],
                    ),
                  ),
                  if (shouldShowExpand) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _isExpanded = !_isExpanded),
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

              if (_detectionResult != null)
                SmartActionButtons(
                  content: displayContent,
                  detectionResult: _detectionResult!,
                  transformerService: widget.transformerService,
                ),

              const SizedBox(height: 10),
              Row(
                children: [
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
    );
  }
}
