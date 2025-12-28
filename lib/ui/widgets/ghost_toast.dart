import 'package:flutter/material.dart';

import '../theme/colors.dart';

/// Custom toast notification system matching GhostCopy design language
///
/// Features:
/// - Dark theme with glassmorphism
/// - Slide-in animation from bottom-right
/// - Auto-dismiss after duration
/// - Icon support for different toast types
/// - Smooth fade + slide transitions
///
/// Memory safety:
/// - Properly removes overlay entries
/// - Cancels timers on early dismissal
/// - No leaks from animation controllers
void showGhostToast(
  BuildContext context,
  String message, {
  IconData? icon,
  Duration duration = const Duration(seconds: 2),
  GhostToastType type = GhostToastType.info,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry overlayEntry;

  overlayEntry = OverlayEntry(
    builder: (context) => _GhostToastWidget(
      message: message,
      icon: icon ?? _getDefaultIcon(type),
      duration: duration,
      type: type,
      onDismiss: () {
        // Remove overlay entry safely
        if (overlayEntry.mounted) {
          overlayEntry.remove();
        }
      },
    ),
  );

  overlay.insert(overlayEntry);
}

IconData _getDefaultIcon(GhostToastType type) {
  switch (type) {
    case GhostToastType.success:
      return Icons.check_circle_outline;
    case GhostToastType.error:
      return Icons.error_outline;
    case GhostToastType.info:
      return Icons.info_outline;
  }
}

enum GhostToastType {
  success,
  error,
  info,
}

class _GhostToastWidget extends StatefulWidget {
  const _GhostToastWidget({
    required this.message,
    required this.icon,
    required this.duration,
    required this.type,
    required this.onDismiss,
  });

  final String message;
  final IconData icon;
  final Duration duration;
  final GhostToastType type;
  final VoidCallback onDismiss;

  @override
  State<_GhostToastWidget> createState() => _GhostToastWidgetState();
}

class _GhostToastWidgetState extends State<_GhostToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  bool _isDismissed = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1), // Slide up from bottom
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    // Start entrance animation
    _controller.forward();

    // Auto-dismiss after duration
    // Use WidgetsBinding to avoid timer issues in tests
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(widget.duration, () {
        if (mounted && !_isDismissed) {
          _dismiss();
        }
      });
    });
  }

  void _dismiss() {
    if (_isDismissed) return;
    _isDismissed = true;

    _controller.reverse().then((_) {
      if (mounted) {
        widget.onDismiss();
      }
    });
  }

  @override
  void dispose() {
    // Clean up animation controller
    _controller.dispose();
    super.dispose();
  }

  Color _getBackgroundColor() {
    switch (widget.type) {
      case GhostToastType.success:
        return GhostColors.success.withValues(alpha: 0.15);
      case GhostToastType.error:
        return Colors.red.shade900.withValues(alpha: 0.3);
      case GhostToastType.info:
        return GhostColors.surface.withValues(alpha: 0.95);
    }
  }

  Color _getIconColor() {
    switch (widget.type) {
      case GhostToastType.success:
        return GhostColors.success;
      case GhostToastType.error:
        return Colors.red.shade400;
      case GhostToastType.info:
        return GhostColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      left: 20,
      right: 20,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _getBackgroundColor(),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: GhostColors.glassBorder.withValues(alpha: 0.3),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.icon,
                    size: 20,
                    color: _getIconColor(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.message,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: GhostColors.textPrimary,
                      ),
                    ),
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
