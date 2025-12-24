import 'dart:async';
import 'dart:convert';

import 'package:clipboard/clipboard.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:hcaptcha/hcaptcha.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/auth_service.dart';
import '../../services/game_mode_service.dart';
import '../../services/impl/security_service.dart';
import '../../services/impl/transformer_service.dart';
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
    this.lifecycleController,
    this.notificationService,
    this.gameModeService,
    super.key,
  });

  final IAuthService authService;
  final IWindowService windowService;
  final ILifecycleController? lifecycleController;
  final INotificationService? notificationService;
  final IGameModeService? gameModeService;

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
  final FocusNode _keyboardFocusNode = FocusNode();

  // Repository and Services
  late final ClipboardRepository _clipboardRepository;
  late final ISettingsService _settingsService;
  late final ISecurityService _securityService;
  late final ITransformerService _transformerService;
  late final IPushNotificationService _pushNotificationService;

  // State
  String _content = '';
  String? _selectedPlatform; // null = "All devices"
  bool _isSending = false;
  String? _errorMessage;
  bool _showHistory = false;
  bool _showSettings = false;
  bool _showAuth = false;
  bool _showCopiedToast = false;
  List<ClipboardItem> _historyItems = [];
  bool _isLoadingHistory = false;
  RealtimeChannel? _realtimeChannel;

  // Text controller listener for cleanup (Task: Memory leak fix)
  late VoidCallback _textControllerListener;

  // Transformer state (for JSON prettify, JWT decoding, color preview)
  ContentDetectionResult? _detectedContentType;
  TransformationResult? _transformationResult;

  // Settings state
  bool _autoSendEnabled = false;
  int _staleDurationMinutes = 5;

  // Rate limiting for performance (prevent database hammering)
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // Edge Function rate limiting (prevent API abuse)
  DateTime? _lastEdgeFunctionCallTime;
  static const Duration _minEdgeFunctionInterval = Duration(seconds: 1);
  int _edgeFunctionCallCount = 0;
  DateTime? _edgeFunctionCallCountResetTime;
  static const int _maxEdgeFunctionCallsPerMinute = 30;

  // Content deduplication (prevent sending duplicate content)
  String _lastSentContentHash = '';

  // Smart auto-receive: Track clipboard staleness
  DateTime? _lastClipboardModificationTime;

  // Auto-receive debouncing (Requirement 11.4)
  Timer? _autoReceiveDebounceTimer;
  Map<String, dynamic>? _pendingAutoReceiveRecord;

  // Auto-send clipboard monitoring
  Timer? _clipboardMonitorTimer;
  String _lastMonitoredClipboard = '';

  @override
  void initState() {
    super.initState();

    // Initialize repository and services
    _clipboardRepository = ClipboardRepository();
    _settingsService = SettingsService();
    _securityService = SecurityService();
    _transformerService = TransformerService();
    _pushNotificationService = PushNotificationService();

    // Initialize settings service and load settings
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
        _detectedContentType = _transformerService.detectContentType(_content);

        // Clear previous transformation result when content changes
        _transformationResult = null;
      });
    };
    _textController.addListener(_textControllerListener);

    // Add window listener
    windowManager.addListener(this);

    // Load initial history
    _loadHistory();

    // Initialize hCaptcha with site key from environment
    final siteKey = dotenv.env['HCAPTCHA_SITE_KEY'];
    if (siteKey != null && siteKey.isNotEmpty) {
      HCaptcha.init(siteKey: siteKey);
      debugPrint('[Spotlight] hCaptcha initialized');
    } else {
      debugPrint('[Spotlight] WARNING: hCaptcha site key not found in .env');
    }

    // Subscribe to real-time updates
    _subscribeToRealtimeUpdates();

    // Start clipboard monitoring if auto-send is enabled
    if (_autoSendEnabled) {
      _startClipboardMonitoring();
    }
  }

  /// Load clipboard history from Supabase
  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);

    try {
      final history = await _clipboardRepository.getHistory(limit: 10);
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
      await _settingsService.initialize();

      // Load saved settings
      final autoSend = await _settingsService.getAutoSendEnabled();
      final staleDuration = await _settingsService.getClipboardStaleDurationMinutes();

      if (mounted) {
        setState(() {
          _autoSendEnabled = autoSend;
          _staleDurationMinutes = staleDuration;
        });
      }
    } on Exception catch (e) {
      debugPrint('Failed to load settings: $e');
    }
  }

  /// Subscribe to real-time clipboard updates
  void _subscribeToRealtimeUpdates() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    // Subscribe to inserts on the clipboard table
    _realtimeChannel = Supabase.instance.client
        .channel('clipboard_changes')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'clipboard',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            debugPrint('Real-time update received: ${payload.eventType}');

            // Check if this is from another device (not current device)
            // Compare device names (hostnames) to differentiate devices
            final deviceName = payload.newRecord['device_name'] as String?;
            final currentDeviceName = ClipboardRepository.getCurrentDeviceName();

            // Only auto-receive if from a different device
            // (different hostname or if device name is not set)
            final isFromDifferentDevice = deviceName != null &&
                currentDeviceName != null &&
                deviceName != currentDeviceName;

            // Check if this message is targeted to this device type
            final targetDeviceType = payload.newRecord['target_device_type'] as String?;
            final currentDeviceType = ClipboardRepository.getCurrentDeviceType();

            // Message is for us if:
            // - target is null (broadcast to all devices)
            // - OR target matches our device type
            final isTargetedToMe = targetDeviceType == null ||
                                   targetDeviceType == currentDeviceType;

            if (isFromDifferentDevice && isTargetedToMe) {
              // Debounce auto-receive to prevent clipboard thrashing (Requirement 11.4)
              // If multiple items arrive quickly, only process the most recent one
              _debouncedAutoReceive(payload.newRecord);
            }

            // Always reload history to show new items
            _loadHistory();
          },
        )
        .subscribe();
  }

  /// Debounce auto-receive to prevent clipboard thrashing
  ///
  /// Requirement 11.4: Copy only the most recent item when multiple arrive quickly
  ///
  /// When multiple items are received in quick succession (e.g., user sends 5 clips
  /// from mobile within 1 second), this debounces the auto-receive logic to only
  /// process the most recent item after a 500ms delay. This prevents:
  /// - Clipboard thrashing (overwriting clipboard multiple times)
  /// - Excessive database queries
  /// - Multiple notifications
  void _debouncedAutoReceive(Map<String, dynamic> record) {
    // Cancel any pending auto-receive operation
    _autoReceiveDebounceTimer?.cancel();

    // Store the most recent record
    _pendingAutoReceiveRecord = record;

    // Schedule processing after 500ms delay
    // If another item arrives within 500ms, this timer will be cancelled
    // and a new one will be created, ensuring only the last item is processed
    _autoReceiveDebounceTimer = Timer(
      const Duration(milliseconds: 500),
      () {
        if (_pendingAutoReceiveRecord != null && mounted) {
          _handleSmartAutoReceive(_pendingAutoReceiveRecord!);
          _pendingAutoReceiveRecord = null;
        }
      },
    );
  }

  /// Handle smart auto-receive logic for new clips from other devices
  ///
  /// Requirement 11.1: Auto-copy to clipboard when received from another device
  /// Requirement 11.2: Show subtle toast notification
  /// Requirement 11.3: Suppress notification when Game Mode is active
  Future<void> _handleSmartAutoReceive(Map<String, dynamic> record) async {
    try {
      final deviceType = record['device_type'] as String? ?? 'unknown';

      // Check if clipboard is stale (hasn't been modified recently)
      final now = DateTime.now();
      final staleDuration = Duration(minutes: _staleDurationMinutes);
      final isStale = _lastClipboardModificationTime == null ||
          now.difference(_lastClipboardModificationTime!) >= staleDuration;

      if (isStale) {
        // Clipboard is stale - auto-copy to clipboard
        // Fetch the latest item from history (it's already decrypted by getHistory)
        final history = await _clipboardRepository.getHistory(limit: 1);

        if (history.isNotEmpty && mounted) {
          final content = history.first.content;
          final item = history.first;

          // Auto-copy to clipboard (Requirement 11.1)
          await FlutterClipboard.copy(content);
          debugPrint('Auto-copied stale clipboard from $deviceType');

          // Update modification time
          _lastClipboardModificationTime = now;

          // Show notification or queue if Game Mode active (Requirement 11.2, 11.3)
          if (widget.gameModeService?.isActive ?? false) {
            // Game Mode active - queue the notification
            widget.gameModeService?.queueNotification(item);
            debugPrint('Game Mode active - notification queued');
          } else {
            // Show notification immediately
            widget.notificationService?.showToast(
              message: 'Auto-copied from $deviceType',
              type: NotificationType.success,
            );
          }
        }
      } else {
        // Clipboard is fresh - just notify user (don't auto-copy)
        final minutesAgo = now.difference(_lastClipboardModificationTime!).inMinutes;
        debugPrint(
          'Clipboard fresh (modified ${minutesAgo}m ago) - not auto-copying',
        );

        // Still show notification about new clip arrival (Requirement 11.2)
        if (widget.gameModeService?.isActive ?? false) {
          // Game Mode active - queue the notification
          final history = await _clipboardRepository.getHistory(limit: 1);
          if (history.isNotEmpty) {
            widget.gameModeService?.queueNotification(history.first);
            debugPrint('Game Mode active - notification queued (fresh clipboard)');
          }
        } else {
          // Show notification about new clip
          widget.notificationService?.showToast(
            message: 'New clip from $deviceType (clipboard not auto-copied)',
            duration: const Duration(seconds: 3),
          );
        }
      }
    } on Exception catch (e) {
      debugPrint('Failed to handle smart auto-receive: $e');
    }
  }

  /// Start clipboard monitoring for auto-send feature
  void _startClipboardMonitoring() {
    // Monitor clipboard every 5 seconds (optimized for minimal background CPU usage)
    _clipboardMonitorTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkClipboardForAutoSend(),
    );
    debugPrint('Clipboard monitoring started');
  }

  /// Stop clipboard monitoring
  void _stopClipboardMonitoring() {
    _clipboardMonitorTimer?.cancel();
    _clipboardMonitorTimer = null;
    _lastMonitoredClipboard = '';
    debugPrint('Clipboard monitoring stopped');
  }

  /// Check clipboard and auto-send if changed
  Future<void> _checkClipboardForAutoSend() async {
    if (!_autoSendEnabled) return;

    try {
      final clipboardContent = await FlutterClipboard.paste();

      // Skip if clipboard is empty or unchanged
      if (clipboardContent.isEmpty ||
          clipboardContent == _lastMonitoredClipboard) {
        return;
      }

      // Update last monitored content
      _lastMonitoredClipboard = clipboardContent;

      // Check rate limiting
      if (_lastSendTime != null) {
        final timeSinceLastSend = DateTime.now().difference(_lastSendTime!);
        if (timeSinceLastSend < _minSendInterval) {
          debugPrint('Auto-send rate limited');
          return;
        }
      }

      // Security check: Detect sensitive data BEFORE auto-send
      // Use async version to avoid blocking UI thread
      final detection = await _securityService.detectSensitiveDataAsync(clipboardContent);
      if (detection.isSensitive) {
        debugPrint(
          'Auto-send blocked: ${detection.type?.label} detected - ${detection.reason}',
        );

        // Show warning notification to user
        if (mounted) {
          setState(() {
            _errorMessage =
                '⚠️ ${detection.type?.label} detected. Auto-send blocked for safety. '
                'You can still manually send if needed.';
          });

          // Auto-clear warning after 5 seconds
          Future<void>.delayed(const Duration(seconds: 5), () {
            if (mounted) {
              setState(() => _errorMessage = null);
            }
          });
        }

        return; // Block auto-send
      }

      // Auto-send the clipboard content
      debugPrint('Auto-sending clipboard: ${clipboardContent.substring(0, clipboardContent.length > 50 ? 50 : clipboardContent.length)}...');
      await _autoSendClipboard(clipboardContent);
    } on Exception catch (e) {
      debugPrint('Auto-send clipboard check failed: $e');
    }
  }

  /// Calculate content hash for deduplication
  String _calculateContentHash(String content) {
    final bytes = utf8.encode(content);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Check if Edge Function rate limit allows call
  bool _canCallEdgeFunction() {
    final now = DateTime.now();

    // Reset counter every minute
    if (_edgeFunctionCallCountResetTime == null ||
        now.difference(_edgeFunctionCallCountResetTime!) >= const Duration(minutes: 1)) {
      _edgeFunctionCallCount = 0;
      _edgeFunctionCallCountResetTime = now;
    }

    // Check per-minute limit
    if (_edgeFunctionCallCount >= _maxEdgeFunctionCallsPerMinute) {
      debugPrint('Edge Function rate limit exceeded: $_edgeFunctionCallCount calls in last minute');
      return false;
    }

    // Check minimum interval between calls
    if (_lastEdgeFunctionCallTime != null) {
      final timeSinceLastCall = now.difference(_lastEdgeFunctionCallTime!);
      if (timeSinceLastCall < _minEdgeFunctionInterval) {
        debugPrint('Edge Function rate limited: ${timeSinceLastCall.inMilliseconds}ms since last call');
        return false;
      }
    }

    return true;
  }

  /// Send Edge Function notification with rate limiting
  Future<void> _sendEdgeFunctionNotification({
    required int clipboardId,
    required String contentPreview,
    required String deviceType,
    String? targetDeviceType,
  }) async {
    if (!_canCallEdgeFunction()) {
      debugPrint('Skipping Edge Function call due to rate limit');
      return;
    }

    _lastEdgeFunctionCallTime = DateTime.now();
    _edgeFunctionCallCount++;

    unawaited(
      _pushNotificationService.sendClipboardNotification(
        clipboardId: clipboardId,
        contentPreview: contentPreview,
        deviceType: deviceType,
        targetDeviceType: targetDeviceType,
      ),
    );
  }

  /// Auto-send clipboard content to Supabase
  /// Sends to devices specified in settings (or all devices if none selected)
  /// Optimized with deduplication and minimal database operations
  Future<void> _autoSendClipboard(String content) async {
    try {
      // Get current user ID
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // OPTIMIZATION: Content deduplication - skip if same content was just sent
      final contentHash = _calculateContentHash(content);
      if (contentHash == _lastSentContentHash) {
        debugPrint('Skipping duplicate content send');
        return;
      }
      _lastSentContentHash = contentHash;

      // Get target devices from settings
      final targetDevices = await _settingsService.getAutoSendTargetDevices();

      final currentDeviceType = ClipboardRepository.getCurrentDeviceType();
      final currentDeviceName = ClipboardRepository.getCurrentDeviceName();
      final contentPreview = content.length > 50 ? content.substring(0, 50) : content;

      // OPTIMIZATION: Always send to broadcast (null target) if no specific devices
      // This is more efficient than multiple inserts
      final item = ClipboardItem(
        id: '0',
        userId: userId,
        content: content,
        deviceName: currentDeviceName,
        deviceType: currentDeviceType,
        targetDeviceType: targetDevices.isEmpty ? null : targetDevices.first,
        createdAt: DateTime.now(),
      );

      final result = await _clipboardRepository.insert(item);

      if (targetDevices.isEmpty) {
        debugPrint('Auto-sent clipboard to all devices');

        // Send notification to all devices
        await _sendEdgeFunctionNotification(
          clipboardId: int.tryParse(result.id) ?? 0,
          contentPreview: contentPreview,
          deviceType: currentDeviceType,
        );
      } else {
        // OPTIMIZATION: Send single notification with first target only
        // For multiple targets, just send to "all" instead of N database inserts
        // This trades perfect targeting for better performance
        debugPrint('Auto-sent clipboard to: ${targetDevices.first}');

        await _sendEdgeFunctionNotification(
          clipboardId: int.tryParse(result.id) ?? 0,
          contentPreview: contentPreview,
          deviceType: currentDeviceType,
          targetDeviceType: targetDevices.first,
        );
      }

      _lastSendTime = DateTime.now();
    } on Exception catch (e) {
      debugPrint('Failed to auto-send clipboard: $e');
    }
  }

  @override
  void dispose() {
    // Wrap in try-catch to ensure all resources are disposed even if one fails
    // This prevents cascading failures and memory leaks
    try {
      // Stop clipboard monitoring
      _clipboardMonitorTimer?.cancel();
    } on Exception catch (e) {
      debugPrint('Error cancelling clipboard monitor timer: $e');
    }

    try {
      // Cancel auto-receive debounce timer to prevent memory leaks
      _autoReceiveDebounceTimer?.cancel();
    } on Exception catch (e) {
      debugPrint('Error cancelling auto-receive timer: $e');
    }

    try {
      // Unsubscribe from real-time updates to prevent memory leaks
      _realtimeChannel?.unsubscribe();
    } on Exception catch (e) {
      debugPrint('Error unsubscribing from realtime channel: $e');
    }

    try {
      // Dispose repository resources (encryption service)
      _clipboardRepository.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing clipboard repository: $e');
    }

    try {
      // Dispose settings service
      _settingsService.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing settings service: $e');
    }

    try {
      // Dispose push notification service
      _pushNotificationService.dispose();
    } on Exception catch (e) {
      debugPrint('Error disposing push notification service: $e');
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
      _keyboardFocusNode.dispose();
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

        // Update clipboard modification time
        _lastClipboardModificationTime = DateTime.now();
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
      final item = ClipboardItem(
        id: '0', // Will be generated by Supabase
        userId: userId,
        content: _content,
        deviceName: ClipboardRepository.getCurrentDeviceName(),
        deviceType: currentDeviceType,
        targetDeviceType: _selectedPlatform, // null = all devices, specific = only that type
        createdAt: DateTime.now(),
      );

      // OPTIMIZATION: Content deduplication
      final contentHash = _calculateContentHash(_content);
      _lastSentContentHash = contentHash;

      // Insert into Supabase
      final result = await _clipboardRepository.insert(item);

      debugPrint('Sent: $_content to ${_selectedPlatform ?? "all"}');

      // Send push notification (client-driven, with rate limiting)
      final contentPreview = _content.length > 50 ? _content.substring(0, 50) : _content;
      await _sendEdgeFunctionNotification(
        clipboardId: int.tryParse(result.id) ?? 0,
        contentPreview: contentPreview,
        deviceType: currentDeviceType,
        targetDeviceType: _selectedPlatform,
      );

      if (mounted) {
        _textController.clear();
        setState(() {
          _content = '';
          _isSending = false;
        });

        // Close window
        await widget.windowService.hideSpotlight();
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

  /// Handle keyboard events
  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.enter) {
        _handleSend();
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        // Close settings/history/auth panels first if open, otherwise close window
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
      } else if (event.logicalKey == LogicalKeyboardKey.keyH &&
          (event.logicalKey == LogicalKeyboardKey.control ||
              event.logicalKey == LogicalKeyboardKey.meta)) {
        // Ctrl/Cmd+H to toggle history
        setState(() => _showHistory = !_showHistory);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
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
                    padding: const EdgeInsets.all(20),
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
            // Copied toast notification
            if (_showCopiedToast) _buildCopiedToast(),
          ],
        ),
      ),
    );
  }

  /// Build header with icon and title
  Widget _buildHeader() {
    return Row(
      children: [
        const Icon(Icons.content_copy, size: 24, color: GhostColors.primary),
        const SizedBox(width: 12),
        Text(
          'GhostCopy',
          style: GhostTypography.headline.copyWith(
            color: GhostColors.textPrimary,
          ),
        ),
        const Spacer(),
        // Settings button with tight hover area
        MouseRegion(
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
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.settings,
                size: 20,
                color: _showSettings
                    ? GhostColors.primary
                    : GhostColors.textSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        // History button with tight hover area
        MouseRegion(
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
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.history,
                size: 20,
                color: _showHistory
                    ? GhostColors.primary
                    : GhostColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build text field for clipboard content
  Widget _buildTextField() {
    return TextField(
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
    );
  }

  /// Build platform selector chips
  Widget _buildPlatformSelector() {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: PlatformType.values.length,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final platform = PlatformType.values[index];
          final isSelected =
              _selectedPlatform == platform.name ||
              (_selectedPlatform == null && platform == PlatformType.all);

          return _PlatformChip(
            label: platform.label,
            icon: platform.icon,
            isSelected: isSelected,
            onTap: () {
              setState(() {
                _selectedPlatform = platform == PlatformType.all
                    ? null
                    : platform.name;
              });
            },
          );
        },
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
            final result = _transformerService.transform(
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
        _transformerService.transform(_content, ContentType.jwt);

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
                    _transformationResult = _transformerService.transform(
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
    // Get the target description
    var targetText = 'all devices';
    if (_selectedPlatform != null) {
      final platform = PlatformType.values.firstWhere(
        (p) => p.name == _selectedPlatform,
        orElse: () => PlatformType.all,
      );
      targetText = platform.label.toLowerCase();
    }

    return Column(
      children: [
        // Target indicator
        if (_selectedPlatform != null)
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

  /// Build copied toast notification
  Widget _buildCopiedToast() {
    return Positioned(
      bottom: 20,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: GhostColors.success,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                'Copied to clipboard',
                style: GhostTypography.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
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
                    settingsService: _settingsService,
                    autoSendEnabled: _autoSendEnabled,
                    staleDurationMinutes: _staleDurationMinutes,
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
                      // Start/stop clipboard monitoring
                      if (value) {
                        _startClipboardMonitoring();
                      } else {
                        _stopClipboardMonitoring();
                      }
                    },
                    onStaleDurationChanged: (value) {
                      setState(() => _staleDurationMinutes = value);
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
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: _historyItems.length,
                          itemBuilder: (context, index) {
                            final item = _historyItems[index];
                            return _HistoryItem(
                              content: item.content,
                              timeAgo: _formatTimeAgo(item.createdAt),
                              device: _capitalizeFirst(item.deviceType),
                              targetDeviceType: item.targetDeviceType,
                              onTap: () {
                                // Copy to text field
                                _textController.text = item.content;
                                _historySlideController.reverse();
                                setState(() {
                                  _content = item.content;
                                  _showHistory = false;
                                  _showCopiedToast = true;
                                });
                                _textFieldFocusNode.requestFocus();

                                // Update clipboard modification time
                                _lastClipboardModificationTime = DateTime.now();

                                // Hide toast after 2 seconds
                                Future<void>.delayed(
                                  const Duration(seconds: 2),
                                  () {
                                    if (mounted) {
                                      setState(() => _showCopiedToast = false);
                                    }
                                  },
                                );
                              },
                            );
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

/// History item widget
class _HistoryItem extends StatefulWidget {
  const _HistoryItem({
    required this.content,
    required this.timeAgo,
    required this.device,
    required this.onTap,
    this.targetDeviceType,
  });

  final String content;
  final String timeAgo;
  final String device;
  final String? targetDeviceType;
  final VoidCallback onTap;

  @override
  State<_HistoryItem> createState() => _HistoryItemState();
}

class _HistoryItemState extends State<_HistoryItem> {
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
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: _isHovered
                ? GhostColors.surface.withValues(alpha: 0.5)
                : Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Content preview (truncated)
                Text(
                  widget.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: GhostColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                // Metadata row
                Row(
                  children: [
                    // Source device icon and name
                    Icon(
                      _getDeviceIcon(widget.device),
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
                    if (widget.targetDeviceType != null) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.arrow_forward,
                        size: 10,
                        color: GhostColors.primary.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _getDeviceIconByType(widget.targetDeviceType!),
                        size: 12,
                        color: GhostColors.primary,
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
            ),
          ),
        ),
      ),
    );
  }

  IconData _getDeviceIcon(String device) {
    return _getDeviceIconByType(device.toLowerCase());
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
