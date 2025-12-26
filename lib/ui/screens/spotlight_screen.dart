import 'dart:async';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/auto_start_service.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/device_service.dart';
import '../../services/game_mode_service.dart';
import '../../services/hotkey_service.dart';
import '../../services/lifecycle_controller.dart';
import '../../services/notification_service.dart';
import '../../services/push_notification_service.dart';
import '../../services/security_service.dart';
import '../../services/settings_service.dart';
import '../../services/transformer_service.dart';
import '../../services/window_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/auth_panel.dart';
import '../widgets/settings_panel.dart';

/// Platform types for device selection
enum PlatformType {
  all('All Devices', Icons.devices),
  windows('Windows', Icons.desktop_windows),
  macos('macOS', Icons.laptop_mac),
  android('Android', Icons.phone_android),
  ios('iOS', Icons.phone_iphone);

  const PlatformType(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Spotlight window for sending clipboard content
/// Discord/Blip-inspired design with glassmorphism
class SpotlightScreen extends StatefulWidget {
  const SpotlightScreen({
    required this.authService,
    required this.windowService,
    required this.settingsService,
    required this.clipboardRepository,
    required this.clipboardSyncService,
    required this.securityService,
    required this.transformerService,
    required this.pushNotificationService,
    this.lifecycleController,
    this.notificationService,
    this.gameModeService,
    this.autoStartService,
    this.hotkeyService,
    this.deviceService,
    this.openSettingsOnShow = false,
    this.onSettingsOpened,
    super.key,
  });

  final IAuthService authService;
  final IWindowService windowService;
  final ISettingsService settingsService;
  final IClipboardRepository clipboardRepository;
  final IClipboardSyncService clipboardSyncService;
  final ISecurityService securityService;
  final ITransformerService transformerService;
  final IPushNotificationService pushNotificationService;
  final ILifecycleController? lifecycleController;
  final INotificationService? notificationService;
  final IGameModeService? gameModeService;
  final IAutoStartService? autoStartService;
  final IHotkeyService? hotkeyService;
  final IDeviceService? deviceService;
  final bool openSettingsOnShow;
  final VoidCallback? onSettingsOpened;

  @override
  State<SpotlightScreen> createState() => _SpotlightScreenState();
}

class _SpotlightScreenState extends State<SpotlightScreen>
    with TickerProviderStateMixin, WindowListener {
  // Animation controllers
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late AnimationController _historySlideController;
  late Animation<Offset> _historySlideAnimation;
  late AnimationController _settingsSlideController;
  late Animation<Offset> _settingsSlideAnimation;
  late AnimationController _authSlideController;
  late Animation<Offset> _authSlideAnimation;

  // Pausable wrappers for lifecycle management (Task 12.1)
  late PausableAnimationController _pausableAnimationController;
  late PausableAnimationController _pausableHistorySlideController;
  late PausableAnimationController _pausableSettingsSlideController;
  late PausableAnimationController _pausableAuthSlideController;

  // Text controllers
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFieldFocusNode = FocusNode();

  // No local services needed - all are passed as singletons

  // State
  String _content = '';
  final Set<String> _selectedPlatforms = {}; // empty = "All devices"
  bool _isSending = false;
  String? _errorMessage;
  bool _showHistory = false;
  bool _showSettings = false;
  bool _showAuth = false;
  List<ClipboardItem> _historyItems = [];
  bool _isLoadingHistory = false;

  // Text controller listener for cleanup (Task: Memory leak fix)
  late VoidCallback _textControllerListener;

  // Transformer state (for JSON prettify, JWT decoding, color preview)
  ContentDetectionResult? _detectedContentType;
  TransformationResult? _transformationResult;

  // Settings state (for UI display only - actual values in SettingsService)
  bool _autoSendEnabled = false;
  int _staleDurationMinutes = 5;
  AutoReceiveBehavior _autoReceiveBehavior = AutoReceiveBehavior.smart;

  // Rate limiting for manual sends only (auto-send handled by ClipboardSyncService)
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // String caching for expensive computations (Performance optimization)
  String? _cachedSendButtonTargetText;

  @override
  void initState() {
    super.initState();

    // Wire up clipboard sync service callback for history refresh
    widget.clipboardSyncService.onClipboardReceived = _loadHistory;

    // Load settings for UI state
    _initializeSettings();

    // Set up animations (150ms, ease-out)
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _scaleAnimation = Tween<double>(begin: 0.95, end: 1).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    // Set up history slide animation (200ms)
    _historySlideController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _historySlideAnimation =
        Tween<Offset>(
          begin: const Offset(1, 0), // Start off-screen to the right
          end: Offset.zero, // End at normal position
        ).animate(
          CurvedAnimation(
            parent: _historySlideController,
            curve: Curves.easeOut,
          ),
        );

    // Set up settings slide animation (200ms)
    _settingsSlideController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _settingsSlideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0), // Start off-screen to the left
      end: Offset.zero, // End at normal position
    ).animate(
      CurvedAnimation(
        parent: _settingsSlideController,
        curve: Curves.easeOut,
      ),
    );

    // Set up auth slide animation (200ms)
    _authSlideController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _authSlideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0), // Start off-screen to the left
      end: Offset.zero, // End at normal position
    ).animate(
      CurvedAnimation(
        parent: _authSlideController,
        curve: Curves.easeOut,
      ),
    );

    // Wrap AnimationControllers in Pausable wrappers and register with LifecycleController
    // for Sleep Mode (Task 12.1). These will be paused when window is hidden, resumed when shown.
    _pausableAnimationController = PausableAnimationController(_animationController);
    _pausableHistorySlideController =
        PausableAnimationController(_historySlideController);
    _pausableSettingsSlideController =
        PausableAnimationController(_settingsSlideController);
    _pausableAuthSlideController =
        PausableAnimationController(_authSlideController);

    widget.lifecycleController?.addPausable(_pausableAnimationController);
    widget.lifecycleController?.addPausable(_pausableHistorySlideController);
    widget.lifecycleController?.addPausable(_pausableSettingsSlideController);
    widget.lifecycleController?.addPausable(_pausableAuthSlideController);

    // Listen to text changes and detect content type
    _textControllerListener = () {
      setState(() {
        _content = _textController.text;

        // Detect content type (JSON, JWT, hex color, etc.)
        _detectedContentType = widget.transformerService.detectContentType(_content);

        // Clear previous transformation result when content changes
        _transformationResult = null;
      });
    };
    _textController.addListener(_textControllerListener);

    // Add window listener
    windowManager.addListener(this);

    // Load initial history
    _loadHistory();

    // Note: hCaptcha is initialized once in main.dart, not here
    // Note: Realtime subscription and clipboard monitoring are handled
    // by ClipboardSyncService (runs persistently in background)

    // Check if we should open settings on startup
    if (widget.openSettingsOnShow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openSettings();
      });
    }
  }

  @override
  void didUpdateWidget(SpotlightScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Check if openSettingsOnShow changed to true
    if (!oldWidget.openSettingsOnShow && widget.openSettingsOnShow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openSettings();
      });
    }
  }

  Future<void> _openSettings() async {
    if (!_showSettings) {
      setState(() => _showSettings = true);
      await _settingsSlideController.forward();
      widget.onSettingsOpened?.call();
    }
  }

  /// Load clipboard history from Supabase
  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);

    try {
      final history = await widget.clipboardRepository.getHistory();
      if (mounted) {
        setState(() {
          _historyItems = history;
          _isLoadingHistory = false;
        });
      }
    } on Exception catch (e) {
      debugPrint('Failed to load history: $e');
      if (mounted) {
        setState(() => _isLoadingHistory = false);
      }
    }
  }

  /// Initialize settings service and load saved settings
  Future<void> _initializeSettings() async {
    try {
      await widget.settingsService.initialize();

      // Load saved settings
      final autoSend = await widget.settingsService.getAutoSendEnabled();
      final staleDuration = await widget.settingsService.getClipboardStaleDurationMinutes();
      final autoReceive = await widget.settingsService.getAutoReceiveBehavior();

      if (mounted) {
        setState(() {
          _autoSendEnabled = autoSend;
          _staleDurationMinutes = staleDuration;
          _autoReceiveBehavior = autoReceive;
        });
      }
    } on Exception catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  @override
  void dispose() {
    // Wrap in try-catch to ensure all resources are disposed even if one fails
    // This prevents cascading failures and memory leaks

    // Note: ClipboardSyncService handles realtime subscription and clipboard monitoring
    // We don't need to clean those up here - they persist in the background

    try {
      // Clear callback from ClipboardSyncService to prevent memory leak
      // (Service holds reference to _loadHistory method which references this widget)
      widget.clipboardSyncService.onClipboardReceived = null;
    } on Exception catch (e) {
      debugPrint('Error clearing clipboard sync callback: $e');
    }

    try {
      // Remove Pausable wrappers from LifecycleController before disposing (Task 12.1)
      // This prevents memory leaks from unbounded Set growth
      widget.lifecycleController?.removePausable(_pausableAuthSlideController);
      widget.lifecycleController?.removePausable(_pausableSettingsSlideController);
      widget.lifecycleController?.removePausable(_pausableHistorySlideController);
      widget.lifecycleController?.removePausable(_pausableAnimationController);
    } on Exception catch (e) {
      debugPrint('Error removing pausable controllers: $e');
    }

    try {
      // Dispose in reverse order of creation
      windowManager.removeListener(this);
    } on Exception catch (e) {
      debugPrint('Error removing window manager listener: $e');
    }

    // Dispose animation controllers (unlikely to throw, but wrapped for safety)
    try {
      _authSlideController.dispose();
      _settingsSlideController.dispose();
      _historySlideController.dispose();
      _animationController.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing animation controllers: $e');
    }

    // Dispose text controllers and focus nodes (unlikely to throw, but wrapped for safety)
    try {
      // Remove text controller listener before disposal (Memory leak fix)
      _textController
        ..removeListener(_textControllerListener)
        ..dispose();
      _textFieldFocusNode.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing controllers and focus nodes: $e');
    }

    super.dispose();
  }

  @override
  void onWindowFocus() {
    // Wait for window to be fully sized/positioned before animating
    // This prevents warped appearance on first few launches
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Trigger animation after window is ready
        _animationController.forward(from: 0);

        // Populate from clipboard and focus
        _populateFromClipboard();
        _textFieldFocusNode.requestFocus();
      }
    });
  }

  @override
  void onWindowBlur() {
    // Hide window when it loses focus (user clicks outside)
    widget.windowService.hideSpotlight();
  }

  /// Populate text field from system clipboard
  Future<void> _populateFromClipboard() async {
    try {
      final content = await FlutterClipboard.paste();
      if (content.isNotEmpty && mounted) {
        setState(() {
          _textController.text = content;
          _content = content;
          // Position cursor at end
          _textController.selection = TextSelection.fromPosition(
            TextPosition(offset: content.length),
          );
        });

        // Notify sync service that clipboard was modified (for staleness tracking)
        widget.clipboardSyncService.updateClipboardModificationTime();
      }
    } on Exception catch (e) {
      // Silently fail if clipboard access denied
      debugPrint('Failed to read clipboard: $e');
    }
  }

  /// Handle send action - sends clipboard to Supabase
  Future<void> _handleSend() async {
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

    setState(() => _isSending = true);

    try {
      // mark last send time early to avoid races
      _lastSendTime = now;

      // Get current user ID
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        throw Exception('Not authenticated');
      }

      // Create clipboard item
      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final targetDevicesList = _selectedPlatforms.isEmpty ? null : _selectedPlatforms.toList();

      final item = ClipboardItem(
        id: '0', // Will be generated by Supabase
        userId: userId,
        content: _content,
        deviceName: ClipboardRepository.getCurrentDeviceName(),
        deviceType: currentDeviceType,
        targetDeviceTypes: targetDevicesList, // null = all devices, list = only those types
        createdAt: DateTime.now(),
      );

      // Insert into Supabase
      final result = await widget.clipboardRepository.insert(item);

      final targetText = _selectedPlatforms.isEmpty
          ? 'all devices'
          : _selectedPlatforms.length == 1
              ? PlatformType.values
                  .firstWhere((p) => p.name == _selectedPlatforms.first)
                  .label
                  .toLowerCase()
              : '${_selectedPlatforms.length} device types';

      debugPrint('Sent: $_content to $targetText');

      // Send push notification via service
      final contentPreview = _content.length > 50 ? _content.substring(0, 50) : _content;
      unawaited(
        widget.pushNotificationService.sendClipboardNotification(
          clipboardId: int.tryParse(result.id) ?? 0,
          contentPreview: contentPreview,
          deviceType: currentDeviceType,
          targetDeviceTypes: targetDevicesList,
        ),
      );

      // Notify ClipboardSyncService to prevent duplicate auto-send
      widget.clipboardSyncService.notifyManualSend(_content);

      if (mounted) {
        // Show success toast
        widget.notificationService?.showToast(
          message: 'Sent to $targetText',
          type: NotificationType.success,
        );

        _textController.clear();
        setState(() {
          _content = '';
          _isSending = false;
        });

        // Close window after a brief delay to show toast
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (mounted) {
          await widget.windowService.hideSpotlight();
        }
      }
    } on ValidationException catch (e) {
      if (mounted) {
        setState(() {
          _isSending = false;
          _errorMessage = 'Validation error: ${e.message}';
        });

        // Auto-clear error after 4 seconds
        Future<void>.delayed(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() => _errorMessage = null);
          }
        });
      }
    } on SecurityException catch (e) {
      if (mounted) {
        setState(() {
          _isSending = false;
          _errorMessage = 'Security error: ${e.message}';
        });

        // Auto-clear error after 4 seconds
        Future<void>.delayed(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() => _errorMessage = null);
          }
        });
      }
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _isSending = false;
          _errorMessage = 'Failed to send: $e';
        });

        // Auto-clear error after 4 seconds
        Future<void>.delayed(const Duration(seconds: 4), () {
          if (mounted) {
            setState(() => _errorMessage = null);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape): const DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (intent) {
              // Handle Escape key
              if (_showAuth) {
                _authSlideController.reverse();
                setState(() => _showAuth = false);
              } else if (_showSettings) {
                _settingsSlideController.reverse();
                setState(() => _showSettings = false);
              } else if (_showHistory) {
                _historySlideController.reverse();
                setState(() => _showHistory = false);
              } else {
                widget.windowService.hideSpotlight();
              }
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          descendantsAreFocusable: true,
          child: Scaffold(
            backgroundColor: GhostColors.surface,
          body: Stack(
          children: [
            // Main content
            FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 50, 20, 20), // Extra top padding for buttons
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 12),
                          _buildTextField(),
                          const SizedBox(height: 10),
                          // Show transformer previews if content is transformable
                          if (_detectedContentType?.isTransformable ?? false)
                            ..._buildTransformerUI(),
                          _buildPlatformSelector(),
                          const SizedBox(height: 12),
                          _buildSendButton(),
                          if (_errorMessage != null) ...[
                            const SizedBox(height: 10),
                            _buildErrorMessage(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Settings button - Top Left
            Positioned(
              top: 12,
              left: 12,
              child: _buildSettingsButton(),
            ),
            // History button - Top Right
            Positioned(
              top: 12,
              right: 12,
              child: _buildHistoryButton(),
            ),
            // Click-outside overlay to close auth
            if (_showAuth)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {
                    _authSlideController.reverse();
                    setState(() => _showAuth = false);
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
            // Click-outside overlay to close settings
            if (_showSettings)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {
                    _settingsSlideController.reverse();
                    setState(() => _showSettings = false);
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
            // Click-outside overlay to close history
            if (_showHistory)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {
                    _historySlideController.reverse();
                    setState(() => _showHistory = false);
                  },
                  child: Container(color: Colors.transparent),
                ),
              ),
            // Auth panel overlay (left side, wider than settings)
            if (_showAuth) _buildAuthPanel(),
            // Settings panel overlay (left side)
            if (_showSettings) _buildSettingsPanel(),
            // History panel overlay (right side)
            if (_showHistory) _buildHistoryPanel(),
          ],
        ), // Close Stack (body)
      ), // Close Scaffold
      ), // Close Focus
    ), // Close Actions
  ); // Close Shortcuts
  }

  /// Build header with icon and title (centered)
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.content_copy, size: 24, color: GhostColors.primary),
        const SizedBox(width: 12),
        Text(
          'GhostCopy',
          style: GhostTypography.headline.copyWith(
            color: GhostColors.textPrimary,
          ),
        ),
      ],
    );
  }

  /// Build settings button for top-left corner
  Widget _buildSettingsButton() {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _showSettings = true);
        _settingsSlideController.forward();
      },
      child: InkWell(
        onTap: () {
          if (_showSettings) {
            _settingsSlideController.reverse();
            setState(() => _showSettings = false);
          } else {
            setState(() => _showSettings = true);
            _settingsSlideController.forward();
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _showSettings
                ? GhostColors.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.settings,
            size: 22,
            color: _showSettings
                ? GhostColors.primary
                : GhostColors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// Build history button for top-right corner
  Widget _buildHistoryButton() {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _showHistory = true);
        _historySlideController.forward();
      },
      child: InkWell(
        onTap: () {
          if (_showHistory) {
            _historySlideController.reverse();
            setState(() => _showHistory = false);
          } else {
            setState(() => _showHistory = true);
            _historySlideController.forward();
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _showHistory
                ? GhostColors.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            Icons.history,
            size: 22,
            color: _showHistory
                ? GhostColors.primary
                : GhostColors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// Build text field for clipboard content
  Widget _buildTextField() {
    return RepaintBoundary(
      // Isolate text field repaints
      child: TextField(
      controller: _textController,
      focusNode: _textFieldFocusNode,
      autofocus: true,
      maxLines: 6,
      minLines: 3,
      style: GhostTypography.body.copyWith(color: GhostColors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Paste or type your content...',
        hintStyle: TextStyle(color: GhostColors.textMuted),
        filled: true,
        fillColor: GhostColors.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: GhostColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
      onSubmitted: (_) => _handleSend(),
      ),
    );
  }

  /// Build platform selector chips (multi-select)
  Widget _buildPlatformSelector() {
    return RepaintBoundary(
      // Isolate platform selector repaints
      child: SizedBox(
        height: 36,
        child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: PlatformType.values.length,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final platform = PlatformType.values[index];
          final isSelected = platform == PlatformType.all
              ? _selectedPlatforms.isEmpty
              : _selectedPlatforms.contains(platform.name);

          return RepaintBoundary(
            // Isolate each chip repaint
            child: _PlatformChip(
            label: platform.label,
            icon: platform.icon,
            isSelected: isSelected,
            onTap: () {
              setState(() {
                if (platform == PlatformType.all) {
                  // Selecting "All" clears all selections
                  _selectedPlatforms.clear();
                } else {
                  // Toggle individual platform
                  if (_selectedPlatforms.contains(platform.name)) {
                    _selectedPlatforms.remove(platform.name);
                  } else {
                    _selectedPlatforms.add(platform.name);
                  }
                }
                // Invalidate send button string cache
                _cachedSendButtonTargetText = null;
              });
            },
            ),
          );
        },
        ),
      ),
    );
  }

  /// Build transformer UI (JSON prettify, JWT decode, color preview)
  List<Widget> _buildTransformerUI() {
    if (_detectedContentType == null) return [];

    final widgets = <Widget>[const SizedBox(height: 10)];

    switch (_detectedContentType!.type) {
      case ContentType.json:
        widgets.add(_buildJsonTransformer());
      case ContentType.jwt:
        widgets.add(_buildJwtTransformer());
      case ContentType.hexColor:
        widgets.add(_buildHexColorPreview());
      case ContentType.plainText:
        break;
    }

    return widgets;
  }

  /// Build JSON prettifier button and preview
  Widget _buildJsonTransformer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          icon: const Icon(Icons.format_align_left, size: 16),
          label: const Text('Prettify JSON'),
          onPressed: () {
            final result = widget.transformerService.transform(
              _content,
              ContentType.json,
            );
            if (result.isSuccess && result.transformedContent != null) {
              setState(() {
                _textController.text = result.transformedContent!;
                _transformationResult = result;
              });
            } else {
              setState(() {
                _errorMessage = result.error ?? 'Failed to prettify JSON';
              });
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: GhostColors.primary.withValues(alpha: 0.8),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ],
    );
  }

  /// Build JWT decoder preview
  Widget _buildJwtTransformer() {
    final result = _transformationResult ??
        widget.transformerService.transform(_content, ContentType.jwt);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: GhostColors.surfaceLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: GhostColors.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.vpn_key, size: 16, color: Colors.amber),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'JWT Token',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.amber,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _transformationResult = widget.transformerService.transform(
                      _content,
                      ContentType.jwt,
                    );
                  });
                },
                child: const Icon(Icons.refresh, size: 14, color: Colors.white60),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (result.error != null)
            Text(
              result.error!,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.redAccent,
              ),
            )
          else if (result.preview != null)
            Text(
              result.preview!,
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Colors.white70,
              ),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  /// Build hex color preview
  Widget _buildHexColorPreview() {
    final colorValue = _detectedContentType!.metadata?['color'] as String?;
    if (colorValue == null) return const SizedBox.shrink();

    try {
      // Parse hex color (support #RGB, #RRGGBB, #RRGGBBAA)
      final colorStr = colorValue.replaceFirst('#', '');
      final hexPrefix = colorStr.length == 6
          ? 'FF$colorStr'
          : colorStr.length == 8
              ? colorStr
              : colorStr.padRight(8, 'F');
      final rgbValue = int.parse(hexPrefix, radix: 16);

      return Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(rgbValue),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: GhostColors.surfaceLight,
                width: 2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Color',
                  style: TextStyle(fontSize: 10, color: Colors.white60),
                ),
                Text(
                  colorValue.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    } on Exception {
      return const SizedBox.shrink();
    }
  }

  /// Build send button
  Widget _buildSendButton() {
    // Get the target description (cached to avoid expensive computation on every rebuild)
    _cachedSendButtonTargetText ??= _selectedPlatforms.isEmpty
        ? 'all devices'
        : _selectedPlatforms.length == 1
            ? PlatformType.values
                .firstWhere((p) => p.name == _selectedPlatforms.first)
                .label
                .toLowerCase()
            : _selectedPlatforms
                .map((name) => PlatformType.values
                    .firstWhere((p) => p.name == name)
                    .label
                    .toLowerCase())
                .join(', ');
    final targetText = _cachedSendButtonTargetText!;

    return RepaintBoundary(
      // Isolate send button repaints
      child: Column(
      children: [
        // Target indicator
        if (_selectedPlatforms.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: GhostColors.surfaceLight,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: GhostColors.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: GhostColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Sending to $targetText only',
                  style: TextStyle(
                    fontSize: 11,
                    color: GhostColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        // Send button
        ElevatedButton(
          onPressed: _isSending ? null : _handleSend,
          style: ElevatedButton.styleFrom(
            backgroundColor: GhostColors.primary,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: _isSending
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.send, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text(
                      'Send',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '⏎',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
        ),
      ],
      ),
    );
  }

  /// Build error message
  Widget _buildErrorMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.red.shade400.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: Colors.red.shade400),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }

  /// Build settings panel (slide-in from left)
  Widget _buildSettingsPanel() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _settingsSlideAnimation,
        child: GestureDetector(
          onTap: () {}, // Prevent closing when clicking inside panel
          child: Container(
            width: 280,
            decoration: BoxDecoration(
              color: GhostColors.surfaceLight,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(5, 0),
                ),
              ],
            ),
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.settings,
                        size: 18,
                        color: GhostColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Settings',
                        style: GhostTypography.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: GhostColors.textSecondary,
                        onPressed: () async {
                          await _settingsSlideController.reverse();
                          setState(() => _showSettings = false);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: GhostColors.surface),
                // Settings content - now using SettingsPanel widget
                Expanded(
                  child: SettingsPanel(
                    authService: widget.authService,
                    settingsService: widget.settingsService,
                    autoSendEnabled: _autoSendEnabled,
                    staleDurationMinutes: _staleDurationMinutes,
                    autoReceiveBehavior: _autoReceiveBehavior,
                    autoStartService: widget.autoStartService,
                    hotkeyService: widget.hotkeyService,
                    deviceService: widget.deviceService,
                    onClose: () async {
                      await _settingsSlideController.reverse();
                      setState(() => _showSettings = false);
                    },
                    onOpenAuth: () async {
                      // Close settings panel first to prevent memory leak
                      await _settingsSlideController.reverse();
                      setState(() {
                        _showSettings = false;
                        _showAuth = true;
                      });
                      await _authSlideController.forward();
                    },
                    onAutoSendChanged: (value) {
                      setState(() => _autoSendEnabled = value);
                      // Start/stop clipboard monitoring in background service
                      if (value) {
                        widget.clipboardSyncService.startClipboardMonitoring();
                      } else {
                        widget.clipboardSyncService.stopClipboardMonitoring();
                      }
                    },
                    onStaleDurationChanged: (value) {
                      setState(() => _staleDurationMinutes = value);
                    },
                    onAutoReceiveBehaviorChanged: (value) {
                      setState(() => _autoReceiveBehavior = value);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthPanel() {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _authSlideAnimation,
        child: GestureDetector(
          onTap: () {}, // Prevent closing when clicking inside panel
          child: Container(
            width: 400, // Wider than Settings (280px)
            decoration: BoxDecoration(
              color: GhostColors.surfaceLight,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(5, 0),
                ),
              ],
            ),
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.lock,
                        size: 18,
                        color: GhostColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.authService.isAnonymous
                            ? 'Upgrade Account'
                            : 'Account Settings',
                        style: GhostTypography.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: GhostColors.textSecondary,
                        onPressed: () async {
                          await _authSlideController.reverse();
                          setState(() => _showAuth = false);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: GhostColors.surface),
                // Auth form - now using AuthPanel widget
                Expanded(
                  child: AuthPanel(
                    authService: widget.authService,
                    onClose: () async {
                      await _authSlideController.reverse();
                      setState(() => _showAuth = false);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Build history panel (slide-in from right)
  Widget _buildHistoryPanel() {
    // Use real history data from Supabase

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _historySlideAnimation,
        child: GestureDetector(
          onTap: () {}, // Prevent closing when clicking inside panel
          child: Container(
            width: 280,
            decoration: BoxDecoration(
              color: GhostColors.surfaceLight,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 20,
                  offset: const Offset(-5, 0),
                ),
              ],
            ),
            child: Column(
              children: [
                // Header
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.history,
                        size: 18,
                        color: GhostColors.primary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recent Clips',
                        style: GhostTypography.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: GhostColors.textPrimary,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        color: GhostColors.textSecondary,
                        onPressed: () {
                          _historySlideController.reverse();
                          setState(() => _showHistory = false);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: GhostColors.surface),
                // History list
                Expanded(
                  child: _isLoadingHistory
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: GhostColors.primary,
                          ),
                        )
                      : _historyItems.isEmpty
                      ? Center(
                          child: Text(
                            'No clipboard history yet',
                            style: TextStyle(
                              color: GhostColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : RepaintBoundary(
                          // Isolate history list repaints
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _historyItems.length,
                            itemBuilder: (context, index) {
                              final item = _historyItems[index];
                              return RepaintBoundary(
                                // Isolate each history item repaint
                                child: _StaggeredHistoryItem(
                              index: index,
                              content: item.content,
                              timeAgo: _formatTimeAgo(item.createdAt),
                              device: _capitalizeFirst(item.deviceType),
                              targetDeviceTypes: item.targetDeviceTypes,
                              onTap: () async {
                                // Copy directly to system clipboard
                                try {
                                  await FlutterClipboard.copy(item.content);

                                  // Notify sync service that clipboard was modified (for staleness tracking)
                                  widget.clipboardSyncService.updateClipboardModificationTime();

                                  // Close history panel
                                  await _historySlideController.reverse();
                                  if (mounted) {
                                    setState(() => _showHistory = false);
                                  }

                                  // Show success notification
                                  widget.notificationService?.showToast(
                                    message: 'Copied to clipboard',
                                    type: NotificationType.success,
                                  );
                                } on Exception catch (e) {
                                  debugPrint('Failed to copy to clipboard: $e');
                                  widget.notificationService?.showToast(
                                    message: 'Failed to copy',
                                    type: NotificationType.error,
                                  );
                                }
                              },
                            ),
                              );
                            },
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

  /// Format DateTime to "X ago" string
  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      final minutes = difference.inMinutes;
      return '$minutes${minutes == 1 ? " min" : " mins"} ago';
    } else if (difference.inHours < 24) {
      final hours = difference.inHours;
      return '$hours${hours == 1 ? " hour" : " hours"} ago';
    } else if (difference.inDays < 7) {
      final days = difference.inDays;
      return '$days${days == 1 ? " day" : " days"} ago';
    } else {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks${weeks == 1 ? " week" : " weeks"} ago';
    }
  }

  /// Capitalize first letter of string
  String _capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }
}

/// Platform selection chip widget
class _PlatformChip extends StatefulWidget {
  const _PlatformChip({
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
  State<_PlatformChip> createState() => _PlatformChipState();
}

class _PlatformChipState extends State<_PlatformChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? GhostColors.primary
                  : _isHovered
                  ? GhostColors.surfaceLight
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: widget.isSelected
                    ? Colors.transparent
                    : GhostColors.surfaceLight,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 14,
                  color: widget.isSelected
                      ? Colors.white
                      : GhostColors.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: widget.isSelected
                        ? Colors.white
                        : GhostColors.textSecondary,
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

/// Staggered history item widget with animation and expand functionality
class _StaggeredHistoryItem extends StatefulWidget {
  const _StaggeredHistoryItem({
    required this.index,
    required this.content,
    required this.timeAgo,
    required this.device,
    required this.onTap,
    this.targetDeviceTypes,
  });

  final int index;
  final String content;
  final String timeAgo;
  final String device;
  final List<String>? targetDeviceTypes;
  final VoidCallback onTap;

  @override
  State<_StaggeredHistoryItem> createState() => _StaggeredHistoryItemState();
}

class _StaggeredHistoryItemState extends State<_StaggeredHistoryItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  bool _isHovered = false;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();

    // Staggered animation: each item starts animating with a delay
    _controller = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // Stagger delay: 50ms per item (0ms for first, 50ms for second, etc.)
    Future<void>.delayed(
      Duration(milliseconds: widget.index * 50),
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
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                color: _isHovered
                    ? GhostColors.surface.withValues(alpha: 0.7)
                    : Colors.transparent,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Content preview with expand button
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            widget.content,
                            maxLines: _isExpanded ? null : 2,
                            overflow: _isExpanded
                                ? TextOverflow.visible
                                : TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: GhostColors.textPrimary,
                            ),
                          ),
                        ),
                        // Expand button (show if content is long)
                        if (widget.content.length > 100) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () =>
                                setState(() => _isExpanded = !_isExpanded),
                            child: AnimatedRotation(
                              turns: _isExpanded ? 0.5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: Icon(
                                Icons.expand_more,
                                size: 16,
                                color: GhostColors.primary
                                    .withValues(alpha: _isHovered ? 1 : 0.6),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Metadata row
                    Row(
                      children: [
                        // Source device icon and name
                        Icon(
                          _getDeviceIconByType(widget.device.toLowerCase()),
                          size: 12,
                          color: GhostColors.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.device,
                          style: TextStyle(
                            fontSize: 11,
                            color: GhostColors.textMuted,
                          ),
                        ),
                        // Show target if specified
                        if (widget.targetDeviceTypes != null && widget.targetDeviceTypes!.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.arrow_forward,
                            size: 10,
                            color: GhostColors.primary
                                .withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 6),
                          // Show first target device icon (or count if multiple)
                          if (widget.targetDeviceTypes!.length == 1)
                            Icon(
                              _getDeviceIconByType(widget.targetDeviceTypes!.first),
                              size: 12,
                              color: GhostColors.primary,
                            )
                          else
                            Text(
                              '${widget.targetDeviceTypes!.length}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: GhostColors.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                        ],
                        const SizedBox(width: 8),
                        Text(
                          '•',
                          style: TextStyle(
                            fontSize: 11,
                            color: GhostColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.timeAgo,
                          style: TextStyle(
                            fontSize: 11,
                            color: GhostColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ), // Close Column
              ), // Close AnimatedContainer
            ), // Close InkWell
          ), // Close Material
        ), // Close MouseRegion
      ), // Close SlideTransition
    ); // Close FadeTransition
  }

  IconData _getDeviceIconByType(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }
}
