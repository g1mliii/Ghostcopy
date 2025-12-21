import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/theme/colors.dart';
import '../../ui/theme/typography.dart';
import '../notification_service.dart';

/// Concrete implementation of universal notification service
///
/// Uses Flutter overlays to show toast notifications with the app's design system
/// This approach is cross-platform and requires no platform-specific code
class NotificationService implements INotificationService {
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
    // Remove any existing toast first
    _removeCurrentToast();

    final overlay = _navigatorKey?.currentState?.overlay;
    if (overlay == null) {
      debugPrint('NotificationService: No overlay available');
      return;
    }

    // Create overlay entry
    _currentOverlay = OverlayEntry(
      builder: (context) => _ToastWidget(
        message: message,
        type: type,
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
                constraints: const BoxConstraints(maxWidth: 400),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: _getBackgroundColor(),
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
                    Icon(
                      _getIcon(),
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: GhostTypography.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
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

  Color _getBackgroundColor() {
    switch (widget.type) {
      case NotificationType.success:
        return GhostColors.success;
      case NotificationType.info:
        return GhostColors.primary;
      case NotificationType.warning:
        return Colors.orange.shade700;
      case NotificationType.error:
        return Colors.red.shade700;
    }
  }

  IconData _getIcon() {
    switch (widget.type) {
      case NotificationType.success:
        return Icons.check_circle;
      case NotificationType.info:
        return Icons.info;
      case NotificationType.warning:
        return Icons.warning;
      case NotificationType.error:
        return Icons.error;
    }
  }
}
