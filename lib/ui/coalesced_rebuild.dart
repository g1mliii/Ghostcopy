import 'package:flutter/widgets.dart';

/// Coalesces many `notifyListeners` calls into a single rebuild per frame.
///
/// A ViewModel can notify several times while one frame is being assembled -
/// history load, send state, device list - and each `setState` would schedule
/// its own rebuild of the whole screen. This collapses them: the first call
/// books a post-frame rebuild, the rest are dropped.
///
/// It existed as an identical method plus an identical flag in both screens;
/// the flag moves in here with it.
mixin CoalescedRebuild<T extends StatefulWidget> on State<T> {
  bool _isRebuildScheduled = false;

  /// Request one rebuild after the current frame.
  void scheduleRebuild() {
    if (!mounted || _isRebuildScheduled) return;

    _isRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isRebuildScheduled = false;
      if (!mounted) return;
      setState(() {});
    });
  }
}
