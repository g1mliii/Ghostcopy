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
