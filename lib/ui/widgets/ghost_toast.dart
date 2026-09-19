import 'dart:async';

import 'package:flutter/material.dart';

import '../platform_adaptive.dart';
import '../theme/animations.dart';
import '../theme/colors.dart';

/// Custom toast notification system matching GhostCopy design language
///
/// Features:
/// - Dark theme, one opaque surface for every type
/// - Slides down from the top, clear of the notch
/// - Auto-dismiss after duration
/// - Icon support for different toast types
/// - Smooth fade + slide transitions
///
/// Memory safety:
/// - Properly removes overlay entries
/// - Cancels timers on early dismissal
/// - No leaks from animation controllers
/// The toast currently on screen, if any.
///
/// Every toast renders at the same spot, so without this a second call simply
/// stacked a new overlay on top of the first - flipping a switch on and off
/// quickly left two or three toasts piled up, each fading on its own timer.
/// One at a time: a new toast replaces whatever is showing.
OverlayEntry? _activeToast;

void showGhostToast(
  BuildContext context,
  String message, {
  IconData? icon,
  Duration duration = const Duration(seconds: 2),
  GhostToastType type = GhostToastType.info,
}) {
  final overlay = Overlay.of(context);

  // Drop whatever is on screen before showing this one. Safe to do early: the
  // widget's dispose() cancels its auto-dismiss timer and animation controller.
  _dismissActiveToast();

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
        // Only clear the reference if this is still the toast on screen - a
        // late dismissal from a replaced toast must not unhook its successor.
        if (identical(_activeToast, overlayEntry)) {
          _activeToast = null;
        }
      },
    ),
  );

  _activeToast = overlayEntry;
  overlay.insert(overlayEntry);
}

void _dismissActiveToast() {
  final current = _activeToast;
  _activeToast = null;
  if (current != null && current.mounted) {
    current.remove();
  }
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

enum GhostToastType { success, error, info }

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
  Timer? _autoDismissTimer; // Cancellable timer (Fix #16)

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: GhostAnimations.slow,
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: GhostAnimations.entranceCurve,
      ),
    );

    _slideAnimation =
        Tween<Offset>(
          begin: const Offset(0, -1), // Slide down from above
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: _controller,
            curve: GhostAnimations.defaultCurve,
          ),
        );

    // Start entrance animation
    _controller.forward();

    // Auto-dismiss after duration - use Timer for cancellation (Fix #16)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoDismissTimer = Timer(widget.duration, () {
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
    // Cancel auto-dismiss timer to prevent memory leaks (Fix #16)
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    // Clean up animation controller
    _controller.dispose();
    super.dispose();
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
    // Top, not bottom. A confirmation at the bottom of a phone screen lands
    // under the thumb that just triggered it and over the send button, and on
    // this screen it covered the very control the user had been aiming at.
    //
    // Offset by the safe area so it clears the notch and Dynamic Island rather
    // than tucking behind them.
    final topInset = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topInset + 12,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                // Capped and centred rather than stretched edge to edge: a
                // three-word confirmation spread across a full phone width
                // reads as a banner, which is heavier than the moment
                // deserves. Same cap the desktop toast uses.
                constraints: const BoxConstraints(maxWidth: 320),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: ShapeDecoration(
                  // One surface colour for every type. Success used to wash the
                    // whole toast in translucent green and error in translucent
                    // red, which sat oddly in an app that is otherwise opaque
                    // and near-black, and made a routine "Copied to clipboard"
                    // louder than the action. The type is still legible from
                    // the icon, which is the part that carries meaning; the
                    // surface just holds the text. Matches the desktop toast in
                    // notification_service.dart.
                    color: GhostColors.surfaceAlpha95,
                  shape: Adaptive.surfaceShape(
                    radius: 12,
                    side: BorderSide(color: GhostColors.glassBorderAlpha30),
                  ),
                  shadows: const [
                    BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 18, color: _getIconColor()),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.2,
                          color: GhostColors.textPrimary,
                        ),
                        maxLines: 2,
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
}
