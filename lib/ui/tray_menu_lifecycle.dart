import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

/// Draw a tray/Spotlight transition even while the native window is hidden.
///
/// Ordinary frame requests are suspended in the hidden lifecycle state. A
/// warm-up frame assembles the replacement widget before the window is shown.
Future<void> renderTrayTransitionFrame() {
  final binding = WidgetsBinding.instance;
  final frame = binding.endOfFrame;
  binding.scheduleWarmUpFrame();
  return frame;
}

/// Keeps window blur events from dismissing a menu that is still opening.
class TrayMenuLifecycle {
  /// [isFocused] checks the native window after flyout blur has settled.
  /// [onDismiss] closes a menu after a real click away.
  TrayMenuLifecycle({required this.isFocused, required this.onDismiss});

  /// Checks whether the native window currently has focus.
  final Future<bool> Function() isFocused;

  /// Dismisses the owning menu after a click away.
  final VoidCallback onDismiss;
  static const Duration _blurGrace = Duration(milliseconds: 500);
  DateTime? _shownAt;
  Timer? _blurRecheck;
  int _revision = 0;
  bool _active = false;

  /// Start a new opening and invalidate the previous menu's focus checks.
  int beginOpening() {
    close();
    _active = true;
    return _revision;
  }

  /// Whether an asynchronous opening still belongs to the current menu.
  bool isCurrent(int revision) => _active && revision == _revision;

  /// Start the blur grace once native showing and focusing have finished.
  void finishOpening(int revision) {
    if (isCurrent(revision)) _shownAt = clock.now();
  }

  /// Invalidate pending native operations and delayed focus checks.
  void close() {
    _active = false;
    _shownAt = null;
    _revision++;
    _blurRecheck?.cancel();
    _blurRecheck = null;
  }

  /// Handle blur from the native window, including its own resize/hide events.
  void onWindowBlur() {
    final shownAt = _shownAt;
    // The hide, resize and taskbar flyout can all blur the window before
    // show/focus completes. Dismissing here would replace the menu with the
    // Spotlight while its opener continues to apply the menu's geometry.
    if (!_active || shownAt == null) return;

    final sinceShown = clock.now().difference(shownAt);
    if (sinceShown >= _blurGrace) {
      onDismiss();
      return;
    }

    final revision = _revision;
    _blurRecheck?.cancel();
    _blurRecheck = Timer(_blurGrace - sinceShown, () {
      unawaited(_dismissIfUnfocused(revision));
    });
  }

  Future<void> _dismissIfUnfocused(int revision) async {
    if (!isCurrent(revision)) return;
    try {
      final focused = await isFocused();
      if (isCurrent(revision) && !focused) onDismiss();
    } on Exception catch (e) {
      debugPrint('[TrayMenu] Could not check window focus: $e');
    }
  }

  /// Cancel callbacks when the owning widget is disposed.
  void dispose() => close();
}
