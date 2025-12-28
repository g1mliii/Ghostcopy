import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timeago/timeago.dart' as timeago;

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/impl/encryption_service.dart';
import '../../services/impl/passphrase_sync_service.dart';
import '../../services/security_service.dart';
import '../../services/transformer_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/ghost_toast.dart';
import '../widgets/smart_action_buttons.dart';
import 'mobile_settings_screen.dart';

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
    super.key,
  });

  final IAuthService authService;
  final IDeviceService deviceService;
  final IClipboardRepository clipboardRepository;
  final ISecurityService securityService;
  final ITransformerService transformerService;

  @override
  State<MobileMainScreen> createState() => _MobileMainScreenState();
}

class _MobileMainScreenState extends State<MobileMainScreen>
    with SingleTickerProviderStateMixin {
  // Paste area state
  final TextEditingController _pasteController = TextEditingController();
  bool _isSending = false;
  String? _sendError;

  // Device selection state
  List<Device> _devices = [];
  final Set<String> _selectedDeviceTypes = {};
  bool _devicesLoading = false;

  // History state
  List<ClipboardItem> _historyItems = [];
  bool _historyLoading = false;
  StreamSubscription<List<ClipboardItem>>? _historySubscription;

  // Encryption service (lazy init)
  EncryptionService? _encryptionService;

  // Performance optimization: Cache decrypted content and detection results
  // Key: item.id, Value: decrypted content
  final Map<String, String> _decryptedContentCache = {};
  // Key: item.id, Value: detection result
  final Map<String, ContentDetectionResult> _detectionCache = {};
  static const int _maxCacheSize = 20; // Mobile: Small cache for 10 items + buffer

  @override
  void initState() {
    super.initState();
    _initializeEncryption();
    _loadDevices();
    _loadHistory();
    _subscribeToRealtimeUpdates();
  }

  @override
  void dispose() {
    // Dispose all resources to prevent memory leaks
    _pasteController.dispose();
    _historySubscription?.cancel();
    _encryptionService?.dispose();

    // Clear caches
    _decryptedContentCache.clear();
    _detectionCache.clear();

    super.dispose();
  }

  Future<void> _initializeEncryption() async {
    final userId = widget.authService.currentUserId;
    if (userId != null) {
      // Initialize with cloud backup support for authenticated users
      _encryptionService = EncryptionService(
        passphraseSyncService: PassphraseSyncService(),
      );
      await _encryptionService!.initialize(userId);
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
          _historyLoading = false;

          // Cleanup cache to prevent unbounded growth
          _cleanupCache();
        });
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to load history: $e');
      if (mounted) {
        setState(() => _historyLoading = false);
      }
    }
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
      final keysToRemove = _decryptedContentCache.keys.take(entriesToRemove).toList();
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
    _historySubscription = widget.clipboardRepository
        .watchHistory()
        .listen((items) {
      if (mounted) {
        final oldFirstId = _historyItems.isNotEmpty ? _historyItems.first.id : null;

        setState(() {
          _historyItems = items;

          // Cleanup cache after update
          _cleanupCache();
        });

        // Auto-copy latest item if it's from another device
        // Note: ClipboardItem doesn't have deviceId, so we auto-copy all new items
        if (items.isNotEmpty) {
          final latest = items.first;
          // Check if this is a new item (different from previous first item)
          if (oldFirstId == null || latest.id != oldFirstId) {
            _autoCopyToClipboard(latest.content);
          }
        }
      }
    }, onError: (Object error) {
      debugPrint('[MobileMain] Realtime subscription error: $error');
    });
  }

  Future<void> _autoCopyToClipboard(String content) async {
    try {
      // Decrypt if needed
      var finalContent = content;
      if (_encryptionService != null) {
        finalContent = await _encryptionService!.decrypt(content);
      }

      await Clipboard.setData(ClipboardData(text: finalContent));
      debugPrint('[MobileMain] ✅ Auto-copied to clipboard');

      // Show toast notification (Requirement 8.3)
      if (mounted) {
        showGhostToast(
          context,
          'Clipboard updated from another device',
          icon: Icons.sync,
          type: GhostToastType.success,
        );
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to auto-copy: $e');
    }
  }

  Future<void> _handleSend() async {
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
      if (_encryptionService != null &&
          await _encryptionService!.isEnabled()) {
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
        deviceType: ClipboardRepository.getCurrentDeviceType(), // Platform-specific: 'android' or 'ios'
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
        setState(() => _isSending = false);

        showGhostToast(
          context,
          'Sent successfully',
          icon: Icons.send,
          type: GhostToastType.success,
        );
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
          style: TextStyle(
            fontSize: 14,
            color: GhostColors.textSecondary,
          ),
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
    await Future.wait([
      _loadDevices(forceRefresh: true),
      _loadHistory(),
    ]);
  }

  Future<void> _handleHistoryItemTap(ClipboardItem item) async {
    try {
      // Decrypt if needed
      var finalContent = item.content;
      if (_encryptionService != null) {
        finalContent = await _encryptionService!.decrypt(item.content);
      }

      await Clipboard.setData(ClipboardData(text: finalContent));

      if (mounted) {
        showGhostToast(
          context,
          'Copied to clipboard',
          icon: Icons.copy,
          type: GhostToastType.success,
          duration: const Duration(seconds: 1),
        );
      }
    } on Exception catch (e) {
      debugPrint('[MobileMain] Failed to copy: $e');
    }
  }

  void _navigateToSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MobileSettingsScreen(
          authService: widget.authService,
          deviceService: widget.deviceService,
        ),
      ),
    );
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
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: GhostColors.primary,
        backgroundColor: GhostColors.surface,
        child: CustomScrollView(
          slivers: [
            // Paste area section
            SliverToBoxAdapter(
              child: _buildPasteArea(),
            ),

            // Device selector chips
            SliverToBoxAdapter(
              child: _buildDeviceSelector(),
            ),

            // Send button
            SliverToBoxAdapter(
              child: _buildSendButton(),
            ),

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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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

            // History list
            _buildHistoryList(),
          ],
        ),
      ),
    );
  }

  Widget _buildPasteArea() {
    return Container(
      margin: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: GhostColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: GhostColors.glassBorder,
        ),
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
                  separatorBuilder: (context, index) => const SizedBox(width: 8),
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
                    final isSelected =
                        _selectedDeviceTypes.contains(device.deviceType);

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
          child: CircularProgressIndicator(
            color: GhostColors.primary,
          ),
        ),
      );
    }

    if (_historyItems.isEmpty) {
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
                'No clipboard history yet',
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
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = _historyItems[index];

            // Use cached decrypted content if available
            final cachedDecrypted = _decryptedContentCache[item.id];
            final cachedDetection = _detectionCache[item.id];

            return RepaintBoundary(
              child: _StaggeredHistoryItem(
                key: ValueKey(item.id), // Stable key for performance
                index: index,
                item: item,
                transformerService: widget.transformerService,
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
          },
          childCount: _historyItems.length,
        ),
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
            color: isSelected
                ? GhostColors.primary
                : GhostColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isSelected
                  ? GhostColors.primary
                  : GhostColors.glassBorder,
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

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.2), // Slide up slightly
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

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
        _isPreviewMode = (widget.cachedDetectionResult!.type == ContentType.json ||
                widget.cachedDetectionResult!.type == ContentType.jwt) &&
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
      final detectionResult = widget.transformerService.detectContentType(
        _decryptedContent ?? content,
      );

      _detectionResult = detectionResult;

      // Notify parent to cache
      widget.onContentDetected?.call(detectionResult);

      // Enable preview mode for JSON/JWT content longer than 200 chars
      _isPreviewMode = (detectionResult.type == ContentType.json ||
              detectionResult.type == ContentType.jwt) &&
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
                border: Border.all(
                  color: GhostColors.glassBorder,
                ),
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
                                      _detectionResult?.type == ContentType.json
                                          ? Icons.code
                                          : Icons.lock_open,
                                      size: 12,
                                      color: GhostColors.primary.withValues(alpha: 0.8),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Preview Mode',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: GhostColors.primary.withValues(alpha: 0.8),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Content text
                            Text(
                              displayContent,
                              maxLines: _isExpanded
                                  ? null
                                  : (_isPreviewMode ? 3 : 2),
                              overflow: _isExpanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: GhostColors.textPrimary,
                                fontFamily: _detectionResult?.type == ContentType.json ||
                                        _detectionResult?.type == ContentType.jwt
                                    ? 'JetBrainsMono'
                                    : null,
                              ),
                            ),
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
