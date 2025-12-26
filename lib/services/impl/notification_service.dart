import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/theme/colors.dart';
import '../../ui/theme/typography.dart';
import '../notification_service.dart';
import '../toast_window_service.dart';
import '../window_service.dart';
import 'toast_window_service.dart';

/// Concrete implementation of universal notification service
///
/// Uses TWO approaches depending on window state:
/// 1. Spotlight VISIBLE: Flutter overlay (current window)
/// 2. Spotlight HIDDEN: Dedicated toast window (independent)
///
/// This ensures toasts are always visible, even when app is in tray.
class NotificationService implements INotificationService {
  NotificationService({IWindowService? windowService, IToastWindowService? toastWindowService})
      : _windowService = windowService,
        _toastWindowService = toastWindowService;

  final IWindowService? _windowService;
  final IToastWindowService? _toastWindowService;

  GlobalKey<NavigatorState>? _navigatorKey;
  OverlayEntry? _currentOverlay;
  Timer? _dismissTimer;

  @override
  void initialize(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
  }

  @override
  void showToast({
    required String message,
    NotificationType type = NotificationType.info,
    Duration duration = const Duration(seconds: 2),
  }) {
    debugPrint('🔔 [NotificationService] showToast: "$message"');

    // Check if Spotlight window is visible
    final isSpotlightVisible = _windowService?.isVisible ?? false;

    if (!isSpotlightVisible && _toastWindowService != null) {
      // Use dedicated toast window when Spotlight is hidden
      debugPrint('🔔 [NotificationService] Using toast window (Spotlight hidden)');
      _showToastInToastWindow(message, type, duration);
    } else {
      // Use overlay when Spotlight is visible
      debugPrint('🔔 [NotificationService] Using overlay (Spotlight visible)');
      _showToastInOverlay(message, type, duration);
    }
  }

  /// Show toast using dedicated toast window (when Spotlight is hidden)
  void _showToastInToastWindow(
    String message,
    NotificationType type,
    Duration duration,
  ) {
    final toastWidget = ToastWidget(
      message: message,
      type: type,
    );

    _toastWindowService?.showToast(toastWidget, duration: duration);
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
      builder: (context) => RepaintBoundary(
        // Isolate toast repaint from main UI
        child: _ToastWidget(
          message: message,
          type: type,
        ),
      ),
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

    if (!isSpotlightVisible && _toastWindowService != null) {
      // For now, show simple toast in toast window (clickable not supported yet)
      // TODO: Implement clickable toast widget for toast window
      debugPrint('🔔 [NotificationService] Showing simplified toast in toast window');
      final toastWidget = ToastWidget(
        message: '$message - $actionLabel',
        type: NotificationType.info,
      );
      _toastWindowService.showToast(toastWidget, duration: duration);
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
      builder: (context) => RepaintBoundary(
        // Isolate toast repaint from main UI
        child: _ClickableToastWidget(
          message: message,
          actionLabel: actionLabel,
          onAction: () {
            onAction();
            _removeCurrentToast();
          },
          onDismiss: _removeCurrentToast,
        ),
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
    _navigatorKey = null;
  }
}

/// Toast widget with slide-in animation
/// Shows in TOP-MIDDLE when Spotlight is open (doesn't block UI)
class _ToastWidget extends StatefulWidget {
  const _ToastWidget({
    required this.message,
    required this.type,
  });

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
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

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
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
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
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

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
