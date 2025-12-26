import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../ui/theme/colors.dart';
import '../../ui/theme/typography.dart';
import '../notification_service.dart';
import '../toast_window_service.dart';

/// Concrete implementation of toast window service
///
/// IMPORTANT: This service requires TWO isolates/processes:
/// 1. Main app process (Spotlight window)
/// 2. Toast window process (dedicated toast overlay)
///
/// Since Flutter desktop doesn't support multiple windows in a single process,
/// we use a simpler approach: Toggle the main window between Spotlight and Toast modes.
///
/// Design:
/// - When toast needed: Temporarily reconfigure window as toast overlay
/// - Transparent background, always-on-top, bottom-right corner
/// - Auto-hide and restore to previous state
/// - Works even when Spotlight is "hidden" (actually minimized)
class ToastWindowService implements IToastWindowService {
  static const double _toastWidth = 400;
  static const double _toastMaxHeight = 100;
  static const double _screenPadding = 20;

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  Widget? _currentToastContent;
  Timer? _hideTimer;
  bool _isShowingToast = false;

  @override
  Future<void> initialize() async {
    // Desktop only
    if (!_isDesktop()) return;

    debugPrint('[ToastWindowService] Initialized');
  }

  @override
  Future<void> showToast(Widget content, {Duration? duration}) async {
    if (!_isDesktop()) return;

    debugPrint('[ToastWindowService] Showing toast (duration: ${duration?.inSeconds}s)');

    // Cancel any existing hide timer
    _hideTimer?.cancel();

    // Update content
    _currentToastContent = content;
    _isShowingToast = true;

    // Trigger rebuild with new content - use markNeedsBuild instead of setState
    // ignore: invalid_use_of_protected_member
    (navigatorKey.currentContext as Element?)?.markNeedsBuild();

    // Configure window as toast overlay
    await _configureAsToast();

    // Auto-hide after duration
    if (duration != null) {
      _hideTimer = Timer(duration, hideToast);
    }
  }

  @override
  Future<void> hideToast() async {
    if (!_isDesktop()) return;
    if (!_isShowingToast) return;

    debugPrint('[ToastWindowService] Hiding toast');

    _hideTimer?.cancel();
    _hideTimer = null;

    await windowManager.hide();
    _isShowingToast = false;
    _currentToastContent = null;

    // Trigger rebuild to clear content - use markNeedsBuild instead of setState
    // ignore: invalid_use_of_protected_member
    (navigatorKey.currentContext as Element?)?.markNeedsBuild();
  }

  /// Configure window for toast display
  Future<void> _configureAsToast() async {
    // Hide first to prevent visual glitches
    await windowManager.hide();

    // Set transparent background
    await windowManager.setBackgroundColor(Colors.transparent);

    // Set frameless and always-on-top
    await windowManager.setAsFrameless();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);

    // Set size
    await windowManager.setSize(const Size(_toastWidth, _toastMaxHeight));

    // Position in bottom-right corner
    await _positionBottomRight();

    // Show window
    await windowManager.show();

    debugPrint('[ToastWindowService] Toast window configured and shown');
  }

  /// Position window in bottom-right corner of screen
  Future<void> _positionBottomRight() async {
    // For better positioning, we should use screen_retriever package
    // For now, use reasonable defaults
    // Windows taskbar is typically 40-48px, so offset by 50px
    const defaultScreenWidth = 1920.0;
    const defaultScreenHeight = 1080.0;

    final x = defaultScreenWidth - _toastWidth - _screenPadding;
    final y = defaultScreenHeight - _toastMaxHeight - _screenPadding - 50; // 50 for taskbar

    await windowManager.setPosition(Offset(x, y));
  }

  /// Check if running on desktop platform
  bool _isDesktop() {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hideTimer = null;
    _currentToastContent = null;
  }

  /// Get current toast content (for rendering)
  Widget? get currentContent => _currentToastContent;

  /// Check if currently showing a toast
  bool get isShowingToast => _isShowingToast;
}

/// Toast widget for standalone toast window
///
/// Displays toast notifications with slide-in animation
class ToastWidget extends StatefulWidget {
  const ToastWidget({
    required this.message,
    required this.type,
    super.key,
  });

  final String message;
  final NotificationType type;

  @override
  State<ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<ToastWidget>
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
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: Align(
          child: Material(
            color: Colors.transparent,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                // Glassmorphism effect matching Spotlight window
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
                  fontSize: 14,
                  letterSpacing: 0.3,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Toast window app - Root widget for dedicated toast window
class ToastWindowApp extends StatefulWidget {
  const ToastWindowApp({
    required this.toastWindowService,
    super.key,
  });

  final ToastWindowService toastWindowService;

  @override
  State<ToastWindowApp> createState() => _ToastWindowAppState();
}

class _ToastWindowAppState extends State<ToastWindowApp> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: widget.toastWindowService.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: widget.toastWindowService.currentContent ?? const SizedBox.shrink(),
      ),
    );
  }
}
