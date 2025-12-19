import 'dart:async';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/clipboard_item.dart';
import '../../repositories/clipboard_repository.dart';
import '../../services/settings_service.dart';
import '../../services/window_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

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
  const SpotlightScreen({required this.windowService, super.key});

  final IWindowService windowService;

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

  // Text controllers
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _keyboardFocusNode = FocusNode();

  // Repository and Services
  late final ClipboardRepository _clipboardRepository;
  late final ISettingsService _settingsService;

  // State
  String _content = '';
  String? _selectedPlatform; // null = "All devices"
  bool _isSending = false;
  String? _errorMessage;
  bool _showHistory = false;
  bool _showSettings = false;
  bool _showCopiedToast = false;
  List<ClipboardItem> _historyItems = [];
  bool _isLoadingHistory = false;
  RealtimeChannel? _realtimeChannel;

  // Settings state
  bool _autoSendEnabled = false;
  int _staleDurationMinutes = 5;

  // Rate limiting for performance (prevent database hammering)
  DateTime? _lastSendTime;
  static const Duration _minSendInterval = Duration(milliseconds: 500);

  // Smart auto-receive: Track clipboard staleness
  DateTime? _lastClipboardModificationTime;

  // Auto-send clipboard monitoring
  Timer? _clipboardMonitorTimer;
  String _lastMonitoredClipboard = '';

  @override
  void initState() {
    super.initState();

    // Initialize repository and services
    _clipboardRepository = ClipboardRepository();
    _settingsService = SettingsService();

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

    // Listen to text changes
    _textController.addListener(() {
      setState(() {
        _content = _textController.text;
      });
    });

    // Add window listener
    windowManager.addListener(this);

    // Load initial history
    _loadHistory();

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

            if (isFromDifferentDevice) {
              // From another device - handle smart auto-copy
              _handleSmartAutoReceive(payload.newRecord);
            }

            // Always reload history to show new items
            _loadHistory();
          },
        )
        .subscribe();
  }

  /// Handle smart auto-receive logic for new clips from other devices
  Future<void> _handleSmartAutoReceive(Map<String, dynamic> record) async {
    try {
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

          // Auto-copy to clipboard
          await FlutterClipboard.copy(content);
          debugPrint('Auto-copied stale clipboard from ${record['device_type']}');

          // Update modification time
          _lastClipboardModificationTime = now;

          // Show toast notification
          setState(() => _showCopiedToast = true);
          Future<void>.delayed(const Duration(seconds: 2), () {
            if (mounted) setState(() => _showCopiedToast = false);
          });
        }
      } else {
        // Clipboard is fresh - just notify user (don't auto-copy)
        debugPrint(
          'Clipboard fresh (modified ${now.difference(_lastClipboardModificationTime!).inMinutes}m ago) - not auto-copying',
        );
        // Could show notification here if we implement notifications
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

      // Auto-send the clipboard content
      debugPrint('Auto-sending clipboard: ${clipboardContent.substring(0, clipboardContent.length > 50 ? 50 : clipboardContent.length)}...');
      await _autoSendClipboard(clipboardContent);
    } on Exception catch (e) {
      debugPrint('Auto-send clipboard check failed: $e');
    }
  }

  /// Auto-send clipboard content to Supabase
  Future<void> _autoSendClipboard(String content) async {
    try {
      // Get current user ID
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // Create clipboard item
      final item = ClipboardItem(
        id: '0',
        userId: userId,
        content: content,
        deviceName: ClipboardRepository.getCurrentDeviceName(),
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        createdAt: DateTime.now(),
      );

      // Insert into Supabase
      await _clipboardRepository.insert(item);
      _lastSendTime = DateTime.now();

      debugPrint('Auto-sent clipboard to Supabase');
    } on Exception catch (e) {
      debugPrint('Failed to auto-send clipboard: $e');
    }
  }

  @override
  void dispose() {
    // Stop clipboard monitoring
    _clipboardMonitorTimer?.cancel();

    // Unsubscribe from real-time updates to prevent memory leaks
    _realtimeChannel?.unsubscribe();

    // Dispose repository resources (encryption service)
    _clipboardRepository.dispose();

    // Dispose settings service
    _settingsService.dispose();

    // Dispose in reverse order of creation
    windowManager.removeListener(this);
    _settingsSlideController.dispose();
    _historySlideController.dispose();
    _animationController.dispose();
    _textController.dispose();
    _textFieldFocusNode.dispose();
    _keyboardFocusNode.dispose();
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
      final item = ClipboardItem(
        id: '0', // Will be generated by Supabase
        userId: userId,
        content: _content,
        deviceName: ClipboardRepository.getCurrentDeviceName(),
        deviceType: ClipboardRepository.getCurrentDeviceType(),
        createdAt: DateTime.now(),
      );

      // Insert into Supabase
      await _clipboardRepository.insert(item);

      debugPrint('Sent: $_content to ${_selectedPlatform ?? "all"}');

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
        // Close settings/history panels first if open, otherwise close window
        if (_showSettings) {
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

  /// Build send button
  Widget _buildSendButton() {
    return ElevatedButton(
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
                        onPressed: () {
                          _settingsSlideController.reverse();
                          setState(() => _showSettings = false);
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: GhostColors.surface),
                // Settings list
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Auto-send toggle
                      _buildSettingToggle(
                        title: 'Auto-send clipboard',
                        subtitle: 'Automatically sync when you copy',
                        value: _autoSendEnabled,
                        onChanged: (value) async {
                          setState(() => _autoSendEnabled = value);
                          await _settingsService.setAutoSendEnabled(value);

                          // Start/stop clipboard monitoring
                          if (value) {
                            _startClipboardMonitoring();
                          } else {
                            _stopClipboardMonitoring();
                          }
                        },
                      ),
                      const SizedBox(height: 20),
                      // Stale duration slider
                      _buildSettingSlider(
                        title: 'Clipboard staleness',
                        subtitle: 'Auto-paste after $_staleDurationMinutes min',
                        value: _staleDurationMinutes.toDouble(),
                        min: 1,
                        max: 60,
                        divisions: 59,
                        onChanged: (value) {
                          setState(() => _staleDurationMinutes = value.toInt());
                        },
                        onChangeEnd: (value) async {
                          await _settingsService
                              .setClipboardStaleDurationMinutes(value.toInt());
                        },
                      ),
                      const SizedBox(height: 20),
                      // Info text
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: GhostColors.surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  size: 14,
                                  color: GhostColors.primary,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Smart Auto-Receive',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: GhostColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'New clips from other devices auto-paste only if your clipboard hasn\'t changed recently.',
                              style: TextStyle(
                                fontSize: 11,
                                color: GhostColors.textMuted,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: GhostColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: GhostColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: GhostColors.primary,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSettingSlider({
    required String title,
    required String subtitle,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: GhostColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 11,
            color: GhostColors.textMuted,
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: GhostColors.primary,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
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
  });

  final String content;
  final String timeAgo;
  final String device;
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
    switch (device.toLowerCase()) {
      case 'windows':
        return Icons.desktop_windows;
      case 'macos':
        return Icons.laptop_mac;
      case 'android':
        return Icons.phone_android;
      case 'ios':
        return Icons.phone_iphone;
      default:
        return Icons.devices;
    }
  }
}
