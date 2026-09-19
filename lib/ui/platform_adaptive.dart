import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme/colors.dart';

/// Platform adaptations for iOS.
///
/// GhostCopy keeps one branded dark look on every platform on purpose - it is a
/// utility, not a stock Material app, so the visual design does not read as
/// "an Android app" on iOS. What iOS users do notice is *interaction*: the
/// gestures and feedback that are muscle memory. These helpers cover that
/// without forking the UI into two trees.
class Adaptive {
  const Adaptive._();

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  /// Desktop has a pointer, and therefore hover.
  ///
  /// The distinction that matters for feedback is not which OS but whether
  /// there is a cursor: hover can show a control reacting before it is
  /// pressed, and touch cannot.
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// iOS and macOS share Apple's scroll and typography conventions.
  static bool get isApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Page route that gives iOS the swipe-from-left-edge back gesture.
  ///
  /// Its absence is the most obvious "this isn't a real iOS app" tell: swiping
  /// from the edge is how iOS users go back, and under MaterialPageRoute
  /// nothing happens at all.
  static Route<T> pageRoute<T>({
    required WidgetBuilder builder,
    bool fullscreenDialog = false,
  }) {
    if (isIOS) {
      return CupertinoPageRoute<T>(
        builder: builder,
        fullscreenDialog: fullscreenDialog,
      );
    }
    return MaterialPageRoute<T>(
      builder: builder,
      fullscreenDialog: fullscreenDialog,
    );
  }

  /// Scroll physics matching the platform: rubber-band on Apple, glow elsewhere.
  ///
  /// AlwaysScrollableScrollPhysics is kept as the parent so short lists still
  /// accept pull-to-refresh.
  static const ScrollPhysics _bouncing = BouncingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );
  static const ScrollPhysics _clamping = ClampingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  static ScrollPhysics get scrollPhysics => isApple ? _bouncing : _clamping;

  /// Confirmation tap for an action that succeeded (copy, send).
  ///
  /// iOS users expect a physical tick on confirmation. On Android the same tap
  /// reads as noise - the platform reserves haptics for longer-press gestures -
  /// so this is deliberately iOS-only rather than "haptics everywhere".
  static void successFeedback() {
    if (isIOS) _fire(HapticFeedback.lightImpact());
  }

  /// Heavier tap for a significant or destructive action.
  static void impactFeedback() {
    if (isIOS) _fire(HapticFeedback.mediumImpact());
  }

  /// Haptics are fire-and-forget; a missing Taptic Engine is never worth
  /// surfacing to the user or failing the action for.
  static void _fire(Future<void> future) {
    future.catchError((Object _) {});
  }

  /// Scroll behaviour with the overscroll effect removed.
  ///
  /// Android 12+ paints a StretchingOverscrollIndicator: dragging past the end
  /// warps the whole list, text and images included. On a dense list of
  /// clipboard rows that reads as the UI bending rather than as a boundary
  /// cue, and it is jarring every single time the user reaches the end.
  ///
  /// This is NOT scroll physics - clamping physics still stretches, because
  /// the indicator is drawn by ScrollBehavior. It has to be suppressed here.
  /// The glow indicator is dropped too, so the boundary is simply where
  /// scrolling stops.
  static const ScrollBehavior scrollBehavior = _NoOverscrollBehavior();

  /// The platform's own indeterminate spinner.
  ///
  /// Material's CircularProgressIndicator IS the native spinner on Android;
  /// on iOS the system control is CupertinoActivityIndicator, which spins a
  /// ring of tapered spokes rather than sweeping an arc. Nothing here shows a
  /// percentage on purpose - uploads are capped at 10MB, so a determinate bar
  /// would be more chrome than the wait deserves.
  static Widget progressIndicator({
    double size = 20,
    double strokeWidth = 2,
    Color? color,
  }) {
    if (isIOS) {
      return CupertinoActivityIndicator(radius: size / 2, color: color);
    }
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: strokeWidth, color: color),
    );
  }

  /// The platform's own rounded-corner shape.
  ///
  /// Apple does not draw a rounded rectangle. Its corners are a superellipse -
  /// a "squircle" - where curvature ramps in continuously instead of switching
  /// from straight to circular arc at a tangent point. It is the most
  /// recognisable piece of geometry in the system, and since iOS 26 leans on
  /// it harder than ever it is what makes a surface read as Apple-drawn or
  /// not. Flutter ships it as RoundedSuperellipseBorder and its own Cupertino
  /// widgets use it.
  ///
  /// Android's own shape genuinely is a rounded rectangle, so this stays
  /// platform-split rather than becoming the app's house shape.
  static OutlinedBorder surfaceShape({
    required double radius,
    BorderSide? side,
  }) {
    final borderRadius = BorderRadius.circular(radius);
    if (isApple) {
      return RoundedSuperellipseBorder(
        borderRadius: borderRadius,
        side: side ?? BorderSide.none,
      );
    }
    return RoundedRectangleBorder(
      borderRadius: borderRadius,
      side: side ?? BorderSide.none,
    );
  }

  /// A yes/no dialog using each platform's own conventions.
  ///
  /// Only for simple title + message + two buttons. Dialogs with custom bodies
  /// (the device selector, for one) stay on AlertDialog - CupertinoAlertDialog
  /// is not built to host arbitrary layout and would look worse, not more
  /// native.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmText,
    String cancelText = 'Cancel',
    bool isDestructive = false,
    IconData? icon,
    Color? confirmColor,
  }) async {
    if (isIOS) {
      final result = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(cancelText),
            ),
            CupertinoDialogAction(
              isDestructiveAction: isDestructive,
              isDefaultAction: !isDestructive,
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(confirmText),
            ),
          ],
        ),
      );
      return result ?? false;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GhostColors.surface,
        title: Row(
          children: [
            // iOS titles are plain text by convention, so the icon is Material
            // only - it is not dropped, it is simply not an iOS idiom.
            if (icon != null) ...[
              Icon(icon, color: confirmColor ?? GhostColors.primary, size: 24),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: GhostColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, color: GhostColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(cancelText),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor:
                  confirmColor ??
                  (isDestructive ? Colors.red.shade400 : GhostColors.primary),
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// Strips the overscroll indicator on every platform.
class _NoOverscrollBehavior extends MaterialScrollBehavior {
  const _NoOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
