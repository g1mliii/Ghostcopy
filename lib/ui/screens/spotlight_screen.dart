import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:window_manager/window_manager.dart';

import '../../locator.dart';
import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/auto_start_service.dart';

import '../../services/clipboard_service.dart';
import '../../services/clipboard_sync_service.dart';
import '../../services/device_service.dart';
import '../../services/file_type_service.dart';

import '../../services/hotkey_service.dart';
import '../../services/impl/encryption_service.dart';

import '../../services/lifecycle_controller.dart';
import '../../services/notification_service.dart';

import '../../services/settings_service.dart';
import '../../services/transformer_service.dart';
import '../../services/window_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../viewmodels/spotlight_viewmodel.dart';
import '../widgets/auth_panel.dart';
import '../widgets/cached_clipboard_image.dart';
import '../widgets/file_preview_widget.dart';
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

/// Navigation panel state for Spotlight window
/// Enforces mutual exclusivity - only one panel can be open at a time
enum SpotlightPanel { none, settings, history, auth }

/// Spotlight window for sending clipboard content
/// Discord/Blip-inspired design with glassmorphism
class SpotlightScreen extends StatefulWidget {
  const SpotlightScreen({
    this.openSettingsOnShow = false,
    this.onSettingsOpened,
    super.key,
  });

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

  // ViewModel - handles business logic and state
  late final SpotlightViewModel _viewModel;

  // Cached locator lookups for UI services
  late final IAuthService _authService = locator<IAuthService>();
  late final IWindowService _windowService = locator<IWindowService>();
  late final ISettingsService _settingsService = locator<ISettingsService>();
  late final INotificationService _notificationService =
      locator<INotificationService>();
  late final IClipboardSyncService _syncService =
      locator<IClipboardSyncService>();
  late final IClipboardRepository _clipboardRepo =
      locator<IClipboardRepository>();
  late final ITransformerService _transformerService =
      locator<ITransformerService>();
  late final ILifecycleController _lifecycleController =
      locator<ILifecycleController>();
  late final IAutoStartService? _autoStartService =
      locator.isRegistered<IAutoStartService>()
      ? locator<IAutoStartService>()
      : null;
  late final IHotkeyService? _hotkeyService =
      locator.isRegistered<IHotkeyService>() ? locator<IHotkeyService>() : null;
  late final IDeviceService? _deviceService =
      locator.isRegistered<IDeviceService>() ? locator<IDeviceService>() : null;

  // UI-only state (not in ViewModel)
  SpotlightPanel _activePanel = SpotlightPanel.none;
  bool get _showHistory => _activePanel == SpotlightPanel.history;
  bool get _showSettings => _activePanel == SpotlightPanel.settings;
  bool get _showAuth => _activePanel == SpotlightPanel.auth;

  // Text controller listener for cleanup (Task: Memory leak fix)
  VoidCallback? _textControllerListener;

  // ViewModel listener for cleanup (CRITICAL: prevents memory leak)
  late VoidCallback _viewModelListener;

  // Track focus time to prevent immediate blur (debounce)
  DateTime? _lastFocusTime;
  bool _isRebuildScheduled = false;

  // Settings state (for UI display only - actual values in SettingsService)
  bool _autoSendEnabled = false;
  int _staleDurationMinutes = 5;
  AutoReceiveBehavior _autoReceiveBehavior = AutoReceiveBehavior.smart;

  @override
  void initState() {
    super.initState();

    // Get singleton ViewModel from locator
    _viewModel = locator<SpotlightViewModel>();

    // Listen to ViewModel changes and trigger UI rebuild
    // Store listener for removal in dispose (CRITICAL: prevents memory leak)
    _viewModelListener = () {
      if (mounted) {
        // Sync text controller with ViewModel content (fixes clipboard populate issue)
        if (_textController.text != _viewModel.content) {
          _textController.text = _viewModel.content;
          // Move cursor to end
          _textController.selection = TextSelection.fromPosition(
            TextPosition(offset: _textController.text.length),
          );
        }
        _scheduleRebuild();
      }
    };
    _viewModel
      ..addListener(_viewModelListener)
      ..initialize(); // Initialize ViewModel (loads history, sets up Realtime callback)

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

    _settingsSlideAnimation =
        Tween<Offset>(
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

    _authSlideAnimation =
        Tween<Offset>(
          begin: const Offset(-1, 0), // Start off-screen to the left
          end: Offset.zero, // End at normal position
        ).animate(
          CurvedAnimation(parent: _authSlideController, curve: Curves.easeOut),
        );

    // Wrap AnimationControllers in Pausable wrappers and register with LifecycleController
    // for Tray Mode. These will be paused when window is hidden, resumed when shown.
    _pausableAnimationController = PausableAnimationController(
      _animationController,
    );
    _pausableHistorySlideController = PausableAnimationController(
      _historySlideController,
    );
    _pausableSettingsSlideController = PausableAnimationController(
      _settingsSlideController,
    );
    _pausableAuthSlideController = PausableAnimationController(
      _authSlideController,
    );

    final lifecycle = _lifecycleController;
    final pausables = [
      (_pausableAnimationController, _animationController),
      (_pausableHistorySlideController, _historySlideController),
      (_pausableSettingsSlideController, _settingsSlideController),
      (_pausableAuthSlideController, _authSlideController),
    ];

    for (final (pausable, controller) in pausables) {
      if (!lifecycle.addPausable(pausable)) {
        debugPrint(
          '[Spotlight] ⚠️ Failed to register pausable - lifecycle limit reached. '
          'Disposing controller to prevent unmanaged animations.',
        );
        // Dispose controller immediately if lifecycle can't manage it
        // This prevents unmanaged animations from running and wasting CPU
        try {
          controller.dispose();
        } on Exception catch (e) {
          debugPrint(
            '[Spotlight] Failed to dispose unregistered controller: $e',
          );
        }
      }
    }

    // Listen to text changes and update ViewModel
    _textControllerListener = () {
      final text = _textController.text;
      // Update ViewModel content (triggers debounced content detection)
      _viewModel.updateContent(text);
    };
    _textController.addListener(_textControllerListener!);

    // Add window listener
    windowManager.addListener(this);

    // Note: hCaptcha is initialized once in main.dart, not here
    // Note: Realtime subscription and clipboard monitoring are handled
    // by ClipboardSyncService (runs persistently in background)

    // Check if we should open settings on startup
    if (widget.openSettingsOnShow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openSettings();
      });
    }

    // Fix for empty UI on first launch:
    // Check if window is already focused when widget mounts.
    // If so, trigger the entry animation manually because onWindowFocus listener
    // might have been registered after the focus event already fired.
    windowManager.isFocused().then((isFocused) {
      if (isFocused && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _animationController.forward(from: 0);
            _viewModel.populateFromClipboard();
            _textFieldFocusNode.requestFocus();
          }
        });
      }
    });
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
      setState(() => _activePanel = SpotlightPanel.settings);
      await _settingsSlideController.forward();
      widget.onSettingsOpened?.call();
    }
  }

  // _viewModel.refreshHistory and _debouncedLoadHistory removed - now in ViewModel

  /// Handle tap on auth overlay to close auth panel
  void _handleAuthOverlayTap() {
    _authSlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Handle tap on settings overlay to close settings panel
  void _handleSettingsOverlayTap() {
    _settingsSlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Handle tap on history overlay to close history panel
  void _handleHistoryOverlayTap() {
    _historySlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Initialize settings service and load saved settings
  Future<void> _initializeSettings() async {
    try {
      await _settingsService.initialize();

      // Load saved settings
      final autoSend = await _settingsService.getAutoSendEnabled();
      final staleDuration = await _settingsService
          .getClipboardStaleDurationMinutes();
      final autoReceive = await _settingsService.getAutoReceiveBehavior();

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
    // Wrap in try-catch to ensure all resources are disposed even if one fails
    // This prevents cascading failures and memory leaks

    // Note: ClipboardSyncService handles realtime subscription and clipboard monitoring
    // We don't need to clean those up here - they persist in the background

    // CRITICAL: Remove ViewModel listener before disposing screen resources.
    // The ViewModel itself is a singleton and is not disposed here.
    try {
      _viewModel.removeListener(_viewModelListener);
    } on Exception catch (e) {
      debugPrint('Error removing ViewModel listener: $e');
    }

    try {
      // Remove Pausable wrappers from LifecycleController before disposing (Task 12.1)
      // This prevents memory leaks from unbounded Set growth
      _lifecycleController
        ..removePausable(_pausableAuthSlideController)
        ..removePausable(_pausableSettingsSlideController)
        ..removePausable(_pausableHistorySlideController)
        ..removePausable(_pausableAnimationController);
    } on Exception catch (e) {
      debugPrint('Error removing pausable controllers: $e');
    }

    try {
      // Dispose in reverse order of creation
      windowManager.removeListener(this);
    } on Exception catch (e) {
      debugPrint('Error removing window manager listener: $e');
    }

    // Clear file picker flag if still set
    try {
      if (_viewModel.isFilePickerOpen) {
        _viewModel.setFilePickerOpen(isOpen: false);
      }
    } on Exception catch (e) {
      debugPrint('Error clearing file picker flag: $e');
    }

    // Dispose animation controllers individually to prevent cascading failures
    final controllers = [
      ('authSlide', _authSlideController),
      ('settingsSlide', _settingsSlideController),
      ('historySlide', _historySlideController),
      ('animation', _animationController),
    ];

    for (final (name, controller) in controllers) {
      try {
        controller.dispose();
      } on Exception catch (e) {
        debugPrint('Error disposing $name controller: $e');
      }
    }

    // Dispose text controllers and focus nodes (unlikely to throw, but wrapped for safety)
    try {
      // Remove text controller listener before disposal (Memory leak fix)
      if (_textControllerListener != null) {
        _textController.removeListener(_textControllerListener!);
      }
      _textController.dispose();
      _textFieldFocusNode.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing controllers and focus nodes: $e');
    }

    super.dispose();
  }

  @override
  void onWindowFocus() {
    _lastFocusTime = DateTime.now();
    // Wait for window to be fully sized/positioned before animating
    // This prevents warped appearance on first few launches
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // Trigger animation after window is ready
        _animationController.forward(from: 0);

        // Populate from clipboard and focus
        _viewModel.populateFromClipboard();
        _textFieldFocusNode.requestFocus();
      }
    });
  }

  @override
  void onWindowBlur() {
    // Debounce: Ignore blur events immediately after focus (prevents flicker/auto-close)
    if (_lastFocusTime != null &&
        DateTime.now().difference(_lastFocusTime!) <
            const Duration(milliseconds: 500)) {
      return;
    }

    // Don't hide window if file picker is open (file picker takes focus)
    if (_viewModel.isFilePickerOpen) {
      return;
    }

    // Hide window when it loses focus (user clicks outside)
    _windowService.hideSpotlight();

    // Aggressive Tray Optimization:
    // 1. Clear clipboard content to release large strings/buffers
    _viewModel.updateClipboardContent(null);

    // 2. Clear Image Cache to release texture memory immediately
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    // 3. Unfocus text fields to release IME resources
    FocusManager.instance.primaryFocus?.unfocus();

    debugPrint('[Spotlight] 📦 Tray Optimizations Applied (Memory Cleared)');
  }

  // _populateFromClipboard and _handleSend removed - now in ViewModel

  /// Wrapper for ViewModel.handleSend that clears text controller and hides window
  Future<void> _handleSend() async {
    await _viewModel.handleSend(
      onSendSuccess: () async {
        if (!mounted) return;

        _textController.clear();

        // Close window after brief delay
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (mounted) {
          await _windowService.hideSpotlight();
        }
      },
    );
  }

  Future<void> _handleFileUpload() async {
    try {
      // Set flag to prevent window blur from closing window
      _viewModel.setFilePickerOpen(isOpen: true);

      final result = await FilePicker.platform.pickFiles(
        onFileLoading: (status) => debugPrint('File loading: $status'),
      );

      // Clear flag after file picker closes
      if (mounted) {
        _viewModel.setFilePickerOpen(isOpen: false);
      }

      if (result == null || result.files.isEmpty) {
        // User cancelled
        return;
      }

      final file = result.files.first;
      final path = file.path;

      if (path == null) {
        throw Exception('File path is null');
      }

      final fileObj = File(path);
      final filename = file.name;

      // Validate file size (10MB limit) - Check BEFORE reading bytes to save memory
      final fileSizeBytes = await fileObj.length();
      if (fileSizeBytes > 10485760) {
        if (mounted) {
          _notificationService.showToast(
            message: 'File too large: $filename (max 10MB)',
            type: NotificationType.error,
          );
        }
        return;
      }

      // Warn for large files (>5MB)
      if (fileSizeBytes > 5242880) {
        if (mounted) {
          final sizeMB = (fileSizeBytes / 1048576).toStringAsFixed(1);
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

          if (!shouldContinue) {
            return;
          }
        }
      }

      // Read file bytes
      final bytes = await fileObj.readAsBytes();

      // Detect file type
      final fileTypeInfo = FileTypeService.instance.detectFromBytes(
        bytes,
        filename,
      );

      // FIXED: Store file in _viewModel.clipboardContent for preview (don't send yet)
      // User will click Send button to actually share it
      if (mounted) {
        // Update ViewModel with file content
        final sizeKB = (bytes.length / 1024).toStringAsFixed(1);
        final displayText = 'File ready to send: $filename ($sizeKB KB)';
        _viewModel.setFileContent(
          ClipboardContent.file(bytes, filename, fileTypeInfo.mimeType),
          displayText,
        );
        _textController.text = displayText;

        _notificationService.showToast(
          message: 'File ready: $filename',
          type: NotificationType.success,
        );

        debugPrint(
          '[Spotlight] File loaded: $filename (${bytes.length} bytes)',
        );
      }
    } on Exception catch (e) {
      debugPrint('[SpotlightScreen] Failed to load file: $e');
      if (mounted) {
        // Clear file picker flag on error
        _viewModel.setFilePickerOpen(isOpen: false);

        _notificationService.showToast(
          message: 'Failed to load file: $e',
          type: NotificationType.error,
        );
      }
    } finally {
      // Ensure flag is always cleared
      if (mounted && _viewModel.isFilePickerOpen) {
        _viewModel.setFilePickerOpen(isOpen: false);
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
                setState(() => _activePanel = SpotlightPanel.none);
              } else if (_showSettings) {
                _settingsSlideController.reverse();
                setState(() => _activePanel = SpotlightPanel.none);
              } else if (_showHistory) {
                _historySlideController.reverse();
                setState(() => _activePanel = SpotlightPanel.none);
              } else {
                // Clear file content to free memory before closing
                if ((_viewModel.clipboardContent?.hasFile ?? false) ||
                    (_viewModel.clipboardContent?.hasImage ?? false)) {
                  setState(() {
                    _viewModel.updateClipboardContent(null);
                    debugPrint(
                      '[Spotlight] Cleared file/image content (freed memory)',
                    );
                  });
                }
                _windowService.hideSpotlight();
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
                        padding: const EdgeInsets.fromLTRB(
                          20,
                          50,
                          20,
                          20,
                        ), // Extra top padding for buttons
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
                              if (_viewModel
                                      .detectedContentType
                                      ?.isTransformable ??
                                  false)
                                ..._buildTransformerUI(),
                              _buildPlatformSelector(),
                              const SizedBox(height: 12),
                              _buildSendButton(),
                              if (_viewModel.errorMessage != null) ...[
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
                Positioned(top: 12, left: 12, child: _buildSettingsButton()),
                // History button - Top Right
                Positioned(top: 12, right: 12, child: _buildHistoryButton()),
                // Click-outside overlay to close auth
                if (_showAuth)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _handleAuthOverlayTap,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                // Click-outside overlay to close settings
                if (_showSettings)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _handleSettingsOverlayTap,
                      child: Container(color: Colors.transparent),
                    ),
                  ),
                // Click-outside overlay to close history
                if (_showHistory)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _handleHistoryOverlayTap,
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
    return _HoverableIconButton(
      icon: Icons.settings,
      isActive: _showSettings,
      onTap: () {
        if (_showSettings) {
          _settingsSlideController.reverse();
          setState(() => _activePanel = SpotlightPanel.none);
        } else {
          setState(() => _activePanel = SpotlightPanel.settings);
          _settingsSlideController.forward();
        }
      },
    );
  }

  /// Build history button for top-right corner
  Widget _buildHistoryButton() {
    return _HoverableIconButton(
      icon: Icons.history,
      isActive: _showHistory,
      onTap: () {
        if (_showHistory) {
          _historySlideController.reverse();
          setState(() => _activePanel = SpotlightPanel.none);
        } else {
          setState(() => _activePanel = SpotlightPanel.history);
          _historySlideController.forward();
        }
      },
    );
  }

  /// Build image preview (shown when clipboard contains image)
  Widget? _buildImagePreview() {
    final content = _viewModel.clipboardContent;
    // Check for null content, no image flag, or missing bytes
    if (content == null || !content.hasImage || content.imageBytes == null) {
      return null;
    }

    final imageBytes = content.imageBytes!;
    final mimeType = content.mimeType ?? 'unknown';
    // Calculate size safely
    final sizeKB = (imageBytes.length / 1024).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
                // Cap DPI scaling at 2x to prevent excessive memory usage on high-DPI displays
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

  /// Build file preview (shown when clipboard contains file)
  Widget? _buildFilePreview() {
    final content = _viewModel.clipboardContent;
    // Check for null content, no file flag, or missing bytes
    if (content == null || !content.hasFile || content.fileBytes == null) {
      return null;
    }

    final fileBytes = content.fileBytes!;
    final filename = content.filename ?? 'file';

    // Create a temporary clipboard item for the preview widget
    final fileTypeInfo = FileTypeService.instance.detectFromBytes(
      fileBytes,
      filename,
    );

    final tempItem = ClipboardItem(
      id: '0',
      userId: '',
      content: '',
      deviceType: '',
      createdAt: DateTime.now(),
      contentType: fileTypeInfo.contentType,
      fileSizeBytes: fileBytes.length,
      metadata: ClipboardMetadata(originalFilename: filename),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: FilePreviewWidget(item: tempItem),
    );
  }

  Widget _buildTextField() {
    // Cache preview widgets to avoid double construction (performance: build once, use twice)
    final cachedFilePreview = _buildFilePreview();
    final cachedImagePreview = _buildImagePreview();

    final hasFile = _viewModel.clipboardContent?.hasFile ?? false;
    final hasImage = _viewModel.clipboardContent?.hasImage ?? false;

    return RepaintBoundary(
      // Isolate text field repaints
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // File preview (if clipboard has file) - cached to avoid double construction
          if (cachedFilePreview != null) cachedFilePreview,
          // Image preview (if clipboard has image) - cached to avoid double construction
          if (cachedImagePreview != null) cachedImagePreview,
          // FIXED: Hide text field when file/image present (text is ignored anyway)
          if (!hasFile && !hasImage)
            TextField(
              controller: _textController,
              focusNode: _textFieldFocusNode,
              autofocus: true,
              maxLines: 6,
              minLines: 3,
              style: GhostTypography.body.copyWith(
                color: GhostColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Paste or type your content...',
                hintStyle: const TextStyle(color: GhostColors.textMuted),
                filled: true,
                fillColor: GhostColors.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(
                    color: GhostColors.primary,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onSubmitted: (_) => _handleSend(),
            ),
          // FIXED: Hide upload button when file/image already loaded
          if (!(_viewModel.clipboardContent?.hasFile ?? false) &&
              !(_viewModel.clipboardContent?.hasImage ?? false))
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _handleFileUpload,
                    icon: const Icon(Icons.upload_file),
                    color: GhostColors.primary,
                    iconSize: 20,
                    tooltip: 'Upload file',
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(),
                    splashRadius: 18,
                  ),
                ],
              ),
            ),
        ],
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
                ? _viewModel.selectedPlatforms.isEmpty
                : _viewModel.selectedPlatforms.contains(platform.name);

            return RepaintBoundary(
              // Isolate each chip repaint
              child: _PlatformChip(
                label: platform.label,
                icon: platform.icon,
                isSelected: isSelected,
                onTap: () {
                  if (platform == PlatformType.all) {
                    // Selecting "All" clears all selections
                    _viewModel.clearPlatformSelection();
                  } else {
                    // Toggle individual platform
                    _viewModel.togglePlatform(platform.name);
                  }
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
    if (_viewModel.detectedContentType == null) return [];

    final widgets = <Widget>[const SizedBox(height: 10)];

    switch (_viewModel.detectedContentType!.type) {
      case TransformerContentType.json:
        widgets.add(_buildJsonTransformer());
      case TransformerContentType.jwt:
        widgets.add(_buildJwtTransformer());
      case TransformerContentType.hexColor:
        widgets.add(_buildHexColorPreview());
      case TransformerContentType.plainText:
        break;
    }

    // Add spacing after transformer widgets to prevent overlap with device selector
    widgets.add(const SizedBox(height: 16));

    return widgets;
  }

  /// Build JSON prettifier button and preview
  Widget _buildJsonTransformer() {
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.format_align_left, size: 16),
            label: const Text('Prettify JSON'),
            onPressed: () async {
              final result = await _transformerService.transform(
                _viewModel.content,
                TransformerContentType.json,
              );
              if (!mounted) return;
              if (result.isSuccess && result.transformedContent != null) {
                setState(() {
                  _textController.text = result.transformedContent!;
                });
              } else {
                // Error handling moved to ViewModel
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: GhostColors.primary.withValues(alpha: 0.8),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build JWT decoder preview
  Widget _buildJwtTransformer() {
    // Use ViewModel's JWT future (managed by content detection)
    // The ViewModel prefetches this when JWT is detected, so trust that.
    // Don't create inline Futures - they can complete after widget disposal.
    final jwtFuture = _viewModel.jwtTransformFuture;
    return FutureBuilder<TransformationResult>(
      future: jwtFuture,
      builder: (context, snapshot) {
        final result = snapshot.data;

        return RepaintBoundary(
          child: Container(
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
                    const Icon(
                      Icons.vpn_key,
                      size: 16,
                      color: GhostColors.warning,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'JWT Token',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: GhostColors.warning,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () async {
                        // Refresh JWT transformation
                        await _transformerService.transform(
                          _viewModel.content,
                          TransformerContentType.jwt,
                        );
                        // Transformation state managed by ViewModel
                      },
                      child: const Icon(
                        Icons.refresh,
                        size: 14,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (result?.error != null)
                  Text(
                    result!.error!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: GhostColors.errorLight,
                    ),
                  )
                else if (result?.preview != null)
                  Text(
                    result!.preview!,
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
          ),
        );
      },
    );
  }

  /// Build hex color preview
  Widget _buildHexColorPreview() {
    final colorValue =
        _viewModel.detectedContentType!.metadata?['color'] as String?;
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

      return RepaintBoundary(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Color(rgbValue),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: GhostColors.surfaceLight, width: 2),
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
        ),
      );
    } on Exception {
      return const SizedBox.shrink();
    }
  }

  /// Build send button
  Widget _buildSendButton() {
    // Get the target description (ViewModel manages cache)
    final targetText =
        _viewModel.cachedSendButtonTargetText ??
        (_viewModel.selectedPlatforms.isEmpty
            ? 'all devices'
            : _viewModel.selectedPlatforms.length == 1
            ? PlatformType.values
                  .firstWhere(
                    (p) => p.name == _viewModel.selectedPlatforms.first,
                  )
                  .label
                  .toLowerCase()
            : _viewModel.selectedPlatforms
                  .map(
                    (name) => PlatformType.values
                        .firstWhere((p) => p.name == name)
                        .label
                        .toLowerCase(),
                  )
                  .join(', '));

    return RepaintBoundary(
      // Isolate send button repaints
      child: Column(
        children: [
          // Target indicator
          if (_viewModel.selectedPlatforms.isNotEmpty)
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
                    style: const TextStyle(
                      fontSize: 11,
                      color: GhostColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          // Send button
          ElevatedButton(
            onPressed: _viewModel.isSending ? null : _handleSend,
            style: ElevatedButton.styleFrom(
              backgroundColor: GhostColors.primary,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: _viewModel.isSending
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
              _viewModel.errorMessage!,
              style: TextStyle(fontSize: 12, color: Colors.red.shade400),
            ),
          ),
        ],
      ),
    );
  }

  /// Build settings panel (slide-in from left)
  Widget _buildSettingsPanel() {
    // Cache settings panel content to prevent rebuilds during animation
    final panelContent = GestureDetector(
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
                    tooltip: 'Close settings', // FIX #27: Accessibility
                    onPressed: () async {
                      await _settingsSlideController.reverse();
                      setState(() => _activePanel = SpotlightPanel.none);
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
                authService: _authService,
                settingsService: _settingsService,
                autoSendEnabled: _autoSendEnabled,
                staleDurationMinutes: _staleDurationMinutes,
                autoReceiveBehavior: _autoReceiveBehavior,
                autoStartService: _autoStartService,
                hotkeyService: _hotkeyService,
                deviceService: _deviceService,
                encryptionService: EncryptionService.instance,
                onEncryptionChanged: _viewModel.refreshHistory,
                onClose: _handleSettingsClose,
                onOpenAuth: () async {
                  // Close settings panel first to prevent memory leak
                  await _settingsSlideController.reverse();
                  setState(() {
                    _activePanel = SpotlightPanel.auth;
                  });
                  await _authSlideController.forward();
                },
                onAutoSendChanged: (value) {
                  setState(() => _autoSendEnabled = value);
                  // Start/stop clipboard monitoring in background service
                  if (value) {
                    _syncService.startClipboardMonitoring();
                  } else {
                    _syncService.stopClipboardMonitoring();
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
    );

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _settingsSlideAnimation,
        child: panelContent,
      ),
    );
  }

  Widget _buildAuthPanel() {
    // Cache auth panel content to prevent rebuilds
    final panelContent = GestureDetector(
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
                  const Icon(Icons.lock, size: 18, color: GhostColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    _authService.isAnonymous
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
                      setState(() => _activePanel = SpotlightPanel.none);
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
                authService: _authService,
                notificationService: _notificationService,
                clipboardSyncService: _syncService,
                onClose: _handleAuthClose,
              ),
            ),
          ],
        ),
      ),
    );

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _authSlideAnimation,
        child: panelContent,
      ),
    );
  }

  /// Handle copying a history item to clipboard
  /// Wrapper for history item copy - closes panel then delegates to ViewModel
  Future<void> _handleHistoryItemCopy(ClipboardItem item) async {
    // 1. Instant Feedback: Close panel and hide window immediately
    // We don't wait for the animation or the copy operation
    if (mounted) {
      setState(() => _activePanel = SpotlightPanel.none);
    }

    // Hide window immediately (Optimistic UI)
    unawaited(_windowService.hideSpotlight());

    // 2. Perform copy in background
    // We act as if it succeeded immediately to the user
    try {
      await _viewModel.handleHistoryItemCopy(item);
    } on Exception catch (e) {
      // If copy fails, we might want to show a system notification since window is hidden
      debugPrint('[Spotlight] Copy failed after hide: $e');
    }

    // Reset panel state for next time
    if (mounted) {
      unawaited(_historySlideController.reverse());
    }
  }

  /// Wrapper for history item delete - delegates to ViewModel
  void _handleHistoryItemDelete(ClipboardItem item) {
    _viewModel.handleHistoryItemDelete(item);
  }

  /// Handle closing the settings panel
  Future<void> _handleSettingsClose() async {
    await _settingsSlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Handle closing the auth panel
  Future<void> _handleAuthClose() async {
    await _authSlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Handle closing the history panel
  Future<void> _handleHistoryClose() async {
    await _historySlideController.reverse();
    setState(() => _activePanel = SpotlightPanel.none);
  }

  /// Build history panel (slide-in from right)
  Widget _buildHistoryPanel() {
    // Cache the panel content to prevent rebuilds during animation (performance)
    final panelContent = GestureDetector(
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
        child: _HistoryPanelContent(
          historyItems: _viewModel.historyItems,
          isLoading: _viewModel.isLoadingHistory,
          clipboardRepository: _clipboardRepo,
          notificationService: _notificationService,
          onClose: _handleHistoryClose,
          onItemTap: _handleHistoryItemCopy,
          onItemDelete: _handleHistoryItemDelete,
        ),
      ),
    );

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      child: SlideTransition(
        position: _historySlideAnimation,
        child: panelContent,
      ),
    );
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

/// History panel content - manages its own search/filter state to prevent
/// parent setState rebuilds from cascading into the history list.
class _HistoryPanelContent extends StatefulWidget {
  const _HistoryPanelContent({
    required this.historyItems,
    required this.isLoading,
    required this.clipboardRepository,
    required this.onClose,
    required this.onItemTap,
    required this.onItemDelete,
    this.notificationService,
  });

  final List<ClipboardItem> historyItems;
  final bool isLoading;
  final IClipboardRepository clipboardRepository;
  final INotificationService? notificationService;
  final Future<void> Function() onClose;
  final void Function(ClipboardItem item) onItemTap;
  final void Function(ClipboardItem item) onItemDelete;

  @override
  State<_HistoryPanelContent> createState() => _HistoryPanelContentState();
}

class _HistoryPanelContentState extends State<_HistoryPanelContent> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<ClipboardItem> _filteredItems = [];
  Timer? _filterTimer;
  static const _searchDebounceDelay = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _filteredItems = widget.historyItems;
  }

  @override
  void didUpdateWidget(_HistoryPanelContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-apply filter when source items actually change
    // Check reference equality (fast path for most updates)
    if (!identical(widget.historyItems, oldWidget.historyItems)) {
      _applyFilter();
    }
  }

  @override
  void dispose() {
    _filterTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _filterHistory(String query) {
    _filterTimer?.cancel();
    _filterTimer = Timer(_searchDebounceDelay, () {
      if (!mounted) return;
      setState(() {
        _searchQuery = query;
        _applyFilter();
      });
    });
  }

  void _applyFilter() {
    if (_searchQuery.trim().isEmpty) {
      _filteredItems = widget.historyItems;
    } else {
      final lowerQuery = _searchQuery.toLowerCase();
      _filteredItems = widget.historyItems.where((item) {
        if (item.content.toLowerCase().contains(lowerQuery)) return true;
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

  String _capitalizeFirst(String text) {
    if (text.isEmpty) return text;
    return text[0].toUpperCase() + text.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.history, size: 18, color: GhostColors.primary),
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
                tooltip: 'Close history', // FIX #27: Accessibility
                onPressed: widget.onClose,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: GhostColors.surface),
        // Search bar
        _HistorySearchBar(
          controller: _searchController,
          onChanged: _filterHistory,
        ),
        // History list
        Expanded(
          child: widget.isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: GhostColors.primary),
                )
              : _filteredItems.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isNotEmpty
                        ? 'No results found'
                        : 'No clipboard history yet',
                    style: const TextStyle(
                      color: GhostColors.textMuted,
                      fontSize: 13,
                    ),
                  ),
                )
              : RepaintBoundary(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _filteredItems.length,
                    itemBuilder: (context, index) {
                      final item = _filteredItems[index];
                      return RepaintBoundary(
                        key: ValueKey(item.id),
                        child: _HistoryItemContent(
                          item: item,
                          clipboardRepository: widget.clipboardRepository,
                          notificationService: widget.notificationService,
                          timeAgo: _formatTimeAgo(item.createdAt),
                          device: _capitalizeFirst(item.deviceType),
                          onDelete: () => widget.onItemDelete(item),
                          onTap: () => widget.onItemTap(item),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// Search bar widget that manages its own state to prevent parent rebuilds
class _HistorySearchBar extends StatefulWidget {
  const _HistorySearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_HistorySearchBar> createState() => _HistorySearchBarState();
}

class _HistorySearchBarState extends State<_HistorySearchBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTextChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChange);
    super.dispose();
  }

  void _handleTextChange() {
    // Rebuild local widget when text changes (for clear button)
    // allowing parent to avoid rebuilding on every keystroke
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: widget.controller,
        onChanged: widget.onChanged,
        style: const TextStyle(color: GhostColors.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search clips...',
          hintStyle: const TextStyle(
            color: GhostColors.textMuted,
            fontSize: 13,
          ),
          prefixIcon: const Icon(
            Icons.search,
            size: 18,
            color: GhostColors.textMuted,
          ),
          suffixIcon: widget.controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  color: GhostColors.textMuted,
                  onPressed: () {
                    widget.controller.clear();
                    widget.onChanged('');
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                )
              : null,
          filled: true,
          fillColor: GhostColors.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Content widget for history item that isolates hover state
class _HistoryItemContent extends StatefulWidget {
  const _HistoryItemContent({
    required this.item,
    required this.clipboardRepository,
    required this.notificationService,
    required this.timeAgo,
    required this.device,
    required this.onTap,
    required this.onDelete,
  });

  final ClipboardItem item;
  final IClipboardRepository clipboardRepository;
  final INotificationService? notificationService;
  final String timeAgo;
  final String device;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_HistoryItemContent> createState() => _HistoryItemContentState();
}

class _HistoryItemContentState extends State<_HistoryItemContent> {
  bool _isHovered = false;
  bool _isExpanded = false;

  /// Build content preview based on content type
  Widget _buildContentPreview() {
    if (widget.item.isFile) {
      return FilePreviewWidget(item: widget.item, compact: true);
    }
    if (widget.item.isImage) {
      return _buildImagePreview();
    }
    if (widget.item.isRichText) {
      return _buildRichTextPreview();
    }
    return Text(
      widget.item.content,
      maxLines: _isExpanded ? null : 2,
      overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13, color: GhostColors.textPrimary),
    );
  }

  /// Build image preview widget
  Widget _buildImagePreview() {
    return CachedClipboardImage(
      item: widget.item,
      clipboardRepository: widget.clipboardRepository,
      height: 80,
      width: double.infinity,
      borderRadius: 6,
      fit: BoxFit.contain,
    );
  }

  /// Build rich text preview widget
  Widget _buildRichTextPreview() {
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
              size: 11,
              color: GhostColors.primary.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: GhostColors.primary.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          widget.item.content,
          maxLines: _isExpanded ? null : 2,
          overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            color: GhostColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Future<void> _handleSaveToComputer() async {
    try {
      if (!widget.item.requiresDownload) return;

      final filename =
          widget.item.metadata?.originalFilename ??
          'file.${widget.item.contentType.value}';

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save File',
        fileName: filename,
      );

      if (savePath != null) {
        final bytes = await widget.clipboardRepository.downloadFile(
          widget.item,
        );

        if (bytes == null || bytes.isEmpty) {
          throw Exception('Failed to download file');
        }

        final file = File(savePath);
        await file.writeAsBytes(bytes);

        widget.notificationService?.showToast(
          message: 'File saved successfully',
          type: NotificationType.success,
        );
      }
    } on Exception catch (e) {
      debugPrint('[History] Save failed: $e');
      widget.notificationService?.showToast(
        message: 'Failed to save file',
        type: NotificationType.error,
      );
    }
  }

  Future<void> _handleDelete() async {
    try {
      await widget.clipboardRepository.delete(widget.item.id);
      widget.onDelete();
      widget.notificationService?.showToast(
        message: 'Item deleted',
        type: NotificationType.success,
      );
    } on Exception catch (e) {
      debugPrint('[History] Delete failed: $e');
      widget.notificationService?.showToast(
        message: 'Failed to delete item',
        type: NotificationType.error,
      );
    }
  }

  void _showContextMenu(BuildContext context, Offset position) {
    if (!mounted) return;
    final overlayState = Overlay.of(context);
    final overlay = overlayState.context.findRenderObject()! as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              Icon(Icons.content_copy, size: 16),
              SizedBox(width: 12),
              Text('Copy to Clipboard'),
            ],
          ),
        ),
        if (widget.item.requiresDownload)
          const PopupMenuItem<String>(
            value: 'save',
            child: Row(
              children: [
                Icon(Icons.save_alt, size: 16),
                SizedBox(width: 12),
                Text('Save to Computer...'),
              ],
            ),
          ),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: Colors.red),
              SizedBox(width: 12),
              Text('Delete', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        widget.onTap();
      } else if (value == 'save') {
        _handleSaveToComputer();
      } else if (value == 'delete') {
        _handleDelete();
      }
    });
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapDown: (details) {
        _showContextMenu(context, details.globalPosition);
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: _isHovered
                  ? GhostColors.surface.withValues(alpha: 0.7)
                  : Colors.transparent,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _buildContentPreview()),
                      if (!widget.item.isImage &&
                          !widget.item.isFile &&
                          widget.item.content.length > 100) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _isExpanded = !_isExpanded),
                          child: AnimatedRotation(
                            turns: _isExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: GhostColors.primary.withValues(
                                alpha: _isHovered ? 1 : 0.6,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        _getDeviceIconByType(widget.device.toLowerCase()),
                        size: 12,
                        color: GhostColors.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.device,
                        style: const TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.arrow_forward,
                        size: 10,
                        color: GhostColors.primary.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 6),
                      if (widget.item.targetDeviceTypes == null ||
                          widget.item.targetDeviceTypes!.isEmpty)
                        Text(
                          'All',
                          style: const TextStyle(
                            fontSize: 11,
                            color: GhostColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (widget.item.targetDeviceTypes!.length == 1)
                        Icon(
                          _getDeviceIconByType(
                            widget.item.targetDeviceTypes!.first,
                          ),
                          size: 12,
                          color: GhostColors.primary,
                        )
                      else
                        Text(
                          '${widget.item.targetDeviceTypes!.length}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: GhostColors.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        '•',
                        style: const TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.timeAgo,
                        style: const TextStyle(
                          fontSize: 11,
                          color: GhostColors.textMuted,
                        ),
                      ),
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

/// Hoverable icon button with local hover state management
///
/// This widget manages its own hover state to prevent parent widget rebuilds
/// when the user hovers over the button. This is a significant performance
/// optimization for large parent widgets like SpotlightScreen.
class _HoverableIconButton extends StatefulWidget {
  const _HoverableIconButton({
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_HoverableIconButton> createState() => _HoverableIconButtonState();
}

class _HoverableIconButtonState extends State<_HoverableIconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isHighlighted = widget.isActive || _isHovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isHighlighted
                ? GhostColors.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            widget.icon,
            size: 22,
            color: isHighlighted
                ? GhostColors.primary
                : GhostColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
