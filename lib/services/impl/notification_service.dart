import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../ui/theme/colors.dart';
import '../../ui/theme/typography.dart';
import '../game_mode_service.dart';
import '../notification_service.dart';
import '../window_service.dart';

/// Concrete implementation of universal notification service
///
/// Uses TWO approaches depending on window state:
/// 1. Spotlight VISIBLE: Flutter overlay (current window)
/// 2. Spotlight HIDDEN: Native System Notifications (Windows/macOS)
///
/// This ensures toasts are always visible, even when app is in tray.
class NotificationService implements INotificationService {
  NotificationService({
    IWindowService? windowService,
    IGameModeService? gameModeService,
  }) : _windowService = windowService,
       _gameModeService = gameModeService;

  final IWindowService? _windowService;
  final IGameModeService? _gameModeService;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  GlobalKey<NavigatorState>? _navigatorKey;
  OverlayEntry? _currentOverlay;
  Timer? _dismissTimer;

  // Track pending actions for system notifications
  final Map<int, VoidCallback> _pendingActions = {};
  final Map<int, String> _actionPayloads =
      {}; // Track payload for each action ID
  final Map<int, DateTime> _actionTimestamps =
      {}; // Track when action was created
  int _notificationIdCounter = 0;

  // Timer to periodically clean up stale actions (memory leak prevention)
  Timer? _actionCleanupTimer;

  @override
  void initialize(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
    _initializeLocalNotifications();
  }

  Future<void> _initializeLocalNotifications() async {
    // Android initialization
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );

    // iOS/macOS initialization
    const darwinSettings = DarwinInitializationSettings();

    // Linux initialization
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
    );

    // Windows initialization
    // Note: In debug mode with 'flutter run', notifications might not appear
    // if a correct AppUserModelID/Shortcut is not set up on the OS.
    // We try to use minimal settings here.
    const windowsSettings = WindowsInitializationSettings(
      appName: 'GhostCopy',
      guid: '2c295777-6228-48b4-82a9-7b7c25c78d06',
      appUserModelId: 'com.ghostcopy.app',
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
      windows: windowsSettings,
    );

    await _flutterLocalNotificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    debugPrint('[NotificationService] Local notifications initialized');

    // Start periodic cleanup of stale actions (every 5 minutes)
    // This prevents memory leaks from dismissed notifications
    _actionCleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanupStaleActions();
    });
  }

  /// Clean up pending actions older than 5 minutes (dismissed notifications)
  void _cleanupStaleActions() {
    final now = DateTime.now();
    final staleIds = <int>[];

    for (final entry in _actionTimestamps.entries) {
      if (now.difference(entry.value).inMinutes >= 5) {
        staleIds.add(entry.key);
      }
    }

    if (staleIds.isNotEmpty) {
      for (final id in staleIds) {
        _pendingActions.remove(id);
        _actionPayloads.remove(id);
        _actionTimestamps.remove(id);
      }
      debugPrint(
        '[NotificationService] Cleaned up ${staleIds.length} stale action(s)',
      );
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    debugPrint(
      '[NotificationService] Notification response: ${response.notificationResponseType}, ID: ${response.id}, Payload: ${response.payload}',
    );

    // Try ID-based lookup first (works on some platforms)
    if (response.id != null && _pendingActions.containsKey(response.id)) {
      final action = _pendingActions[response.id];
      if (action != null) {
        debugPrint(
          '[NotificationService] Executing pending action for ID: ${response.id}',
        );
        action();
        _pendingActions.remove(response.id);
        _actionPayloads.remove(response.id);
        _actionTimestamps.remove(response.id);
        return;
      }
    }

    // Fallback: Use payload-based lookup (for Windows where ID is null)
    if (response.payload != null && response.payload!.isNotEmpty) {
      // Find action by searching for matching payload
      final matchingEntry = _pendingActions.entries.firstWhere(
        (entry) => _actionPayloads[entry.key] == response.payload,
        orElse: () => MapEntry(-1, () {}),
      );

      if (matchingEntry.key != -1) {
        debugPrint(
          '[NotificationService] Executing action via payload: ${response.payload}',
        );
        matchingEntry.value();
        _pendingActions.remove(matchingEntry.key);
        _actionPayloads.remove(matchingEntry.key);
        _actionTimestamps.remove(matchingEntry.key);
      }
    }
  }

  // ...

  @override
  void showToast({
    required String message,
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    // 1. Check Game Mode
    if (_gameModeService?.isActive ?? false) {
      debugPrint(
        '🔕 [NotificationService] Suppressed toast (Game Mode active)',
      );
      return;
    }

    debugPrint('🔔 [NotificationService] showToast: "$message"');

    // Check if Spotlight window is visible
    final isSpotlightVisible = _windowService?.isVisible ?? false;

    if (!isSpotlightVisible) {
      // Use system notification when Spotlight is hidden
      debugPrint(
        '🔔 [NotificationService] Using system notification (Spotlight hidden)',
      );
      _showSystemNotification(message: message, type: type);
    } else {
      // Use overlay when Spotlight is visible
      debugPrint('🔔 [NotificationService] Using overlay (Spotlight visible)');
      _showToastInOverlay(message, type, duration);
    }
  }

  Future<void> _showSystemNotification({
    required String message,
    NotificationType type = NotificationType.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) async {
    // Double check Game Mode (in case called directly)
    if (_gameModeService?.isActive ?? false) {
      debugPrint(
        '🔕 [NotificationService] Suppressed system notification (Game Mode active)',
      );
      return;
    }

    final id = _notificationIdCounter++;

    // Store action if provided
    if (onAction != null) {
      _pendingActions[id] = onAction;
      _actionTimestamps[id] = DateTime.now(); // Track creation time for cleanup
      if (actionLabel != null) {
        _actionPayloads[id] =
            actionLabel; // Store payload for Windows ID-less responses
      }
    }

    // Configure platform specific details
    const androidDetails = AndroidNotificationDetails(
      'ghostcopy_notifications',
      'GhostCopy Notifications',
      channelDescription: 'General app notifications',
      importance: Importance.high,
      priority: Priority.high,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const linuxDetails = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.normal,
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
      windows: const WindowsNotificationDetails(),
    );

    // Title based on type
    var title = 'GhostCopy';
    switch (type) {
      case NotificationType.success:
        title = 'Success';
        break;
      case NotificationType.error:
        title = 'Error';
        break;
      case NotificationType.warning:
        title = 'Warning';
        break;
      case NotificationType.info:
        title = 'GhostCopy'; // Default app name
        break;
    }

    // Append action hint to body if there's an action but current platform
    // might not support buttons effectively or for clarity
    var body = message;
    if (actionLabel != null) {
      body = '$message\n(Tap to $actionLabel)';
    }

    try {
      debugPrint(
        '[NotificationService] Attempting to show system notification ID: $id',
      );
      await _flutterLocalNotificationsPlugin.show(
        id,
        title,
        body,
        details,
        payload: actionLabel,
      );
      debugPrint(
        '[NotificationService] System notification command sent successfully for ID: $id',
      );
    } on Exception catch (e, stack) {
      debugPrint(
        '❌ [NotificationService] Failed to show system notification: $e',
      );
      debugPrintStack(stackTrace: stack);
    }
  }

  /// Show toast using Flutter overlay (when Spotlight is visible)
  void _showToastInOverlay(
    String message,
    NotificationType type,
    Duration duration,
  ) {
    // Remove any existing toast first
    _removeCurrentToast();

    final overlay = _navigatorKey?.currentState?.overlay;
    if (overlay == null) {
      debugPrint('❌ [NotificationService] No overlay available');
      return;
    }

    // Create overlay entry
    _currentOverlay = OverlayEntry(
      builder: (context) => _ToastWidget(message: message, type: type),
    );

    // Insert into overlay
    overlay.insert(_currentOverlay!);

    // Auto-dismiss after duration
    _dismissTimer = Timer(duration, _removeCurrentToast);
  }

  @override
  void showClipboardNotification({
    required String content,
    required String deviceType,
  }) {
    // Truncate content for notification
    final truncatedContent = content.length > 50
        ? '${content.substring(0, 50)}...'
        : content;

    showToast(
      message: 'Clipboard from $deviceType: $truncatedContent',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  void showClickableToast({
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    debugPrint('🔔 [NotificationService] showClickableToast: "$message"');

    // Check if Spotlight window is visible
    final isSpotlightVisible = _windowService?.isVisible ?? false;

    if (!isSpotlightVisible) {
      // Use system notification with action
      debugPrint(
        '🔔 [NotificationService] Using system notification with action',
      );
      _showSystemNotification(
        message: message,
        actionLabel: actionLabel,
        onAction: onAction,
      );
    } else {
      // Use clickable overlay when Spotlight is visible
      debugPrint('🔔 [NotificationService] Using clickable overlay');
      _showClickableToastInOverlay(message, actionLabel, onAction, duration);
    }
  }

  /// Show clickable toast using Flutter overlay (when Spotlight is visible)
  void _showClickableToastInOverlay(
    String message,
    String actionLabel,
    VoidCallback onAction,
    Duration duration,
  ) {
    // Remove any existing toast first
    _removeCurrentToast();

    final overlay = _navigatorKey?.currentState?.overlay;
    if (overlay == null) {
      debugPrint('❌ [NotificationService] No overlay available');
      return;
    }

    // Create clickable overlay entry
    _currentOverlay = OverlayEntry(
      builder: (context) => _ClickableToastWidget(
        message: message,
        actionLabel: actionLabel,
        onAction: () {
          onAction();
          _removeCurrentToast();
        },
        onDismiss: _removeCurrentToast,
      ),
    );

    // Insert into overlay
    overlay.insert(_currentOverlay!);

    // Auto-dismiss after duration
    _dismissTimer = Timer(duration, _removeCurrentToast);
  }

  /// Remove the current toast overlay
  void _removeCurrentToast() {
    _dismissTimer?.cancel();
    _dismissTimer = null;

    _currentOverlay?.remove();
    _currentOverlay = null;
  }

  @override
  void dispose() {
    _removeCurrentToast();
    _actionCleanupTimer?.cancel();
    _actionCleanupTimer = null;
    _navigatorKey = null;
    _pendingActions.clear();
    _actionPayloads.clear();
    _actionTimestamps.clear();
  }
}

/// Toast widget with slide-in animation
/// Shows in TOP-MIDDLE when Spotlight is open (doesn't block UI)
class _ToastWidget extends StatefulWidget {
  const _ToastWidget({required this.message, required this.type});

  final String message;
  final NotificationType type;

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    // Slide down from top (instead of up from bottom)
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1), // Start above (hidden)
      end: Offset.zero, // End at position
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Position at TOP-MIDDLE (between settings and history buttons)
    return Positioned(
      top: 16, // Just below top edge
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  // Glassmorphism matching app theme
                  color: GhostColors.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Text(
                  widget.message,
                  style: GhostTypography.body.copyWith(
                    color: Colors.white.withValues(alpha: 0.95),
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                    letterSpacing: 0.2,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Clickable toast widget with action button
class _ClickableToastWidget extends StatefulWidget {
  const _ClickableToastWidget({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  State<_ClickableToastWidget> createState() => _ClickableToastWidgetState();
}

class _ClickableToastWidgetState extends State<_ClickableToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1), // Start below
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 20,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 500),
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: GhostColors.primary,
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
                    // Message
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.content_copy,
                              size: 18,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                widget.message,
                                style: GhostTypography.body.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Action button
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: widget.onAction,
                        borderRadius: const BorderRadius.only(
                          topRight: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(8),
                              bottomRight: Radius.circular(8),
                            ),
                          ),
                          child: Text(
                            widget.actionLabel,
                            style: GhostTypography.body.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Dismiss button
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      color: Colors.white.withValues(alpha: 0.7),
                      onPressed: widget.onDismiss,
                      constraints: const BoxConstraints(),
                      padding: const EdgeInsets.all(8),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
