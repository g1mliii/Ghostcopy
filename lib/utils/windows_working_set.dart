import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ask Windows to stop keeping this process's pages resident.
///
/// Hidden, GhostCopy sits at roughly 107 MB of working set that is mostly
/// mapped modules - the GPU driver and the Flutter engine - which nothing in
/// the app can release. Trimming moves those pages to the standby list, where
/// the OS can reuse them and hands them back on a soft fault. Measured on the
/// packaged build: about 107 MB down to under 20 MB, and reopening the
/// Spotlight afterwards still took 16-42 ms.
///
/// Honest about what it is not: committed memory does not change, so this is
/// not the app needing less. It is the app not holding physical pages it is
/// not using during the hours it spends in the tray, which is nearly all of
/// its life.
///
/// No-op off Windows, and silent when the runner has no handler - a missing
/// optimisation must never be an error.
Future<void> trimWindowsWorkingSet() async {
  if (!Platform.isWindows) return;
  try {
    await const MethodChannel(
      'com.ghostcopy.app/memory',
    ).invokeMethod<bool>('trimWorkingSet');
  } on PlatformException catch (e) {
    debugPrint('[Memory] Working set trim failed: ${e.message}');
  } on MissingPluginException {
    // An older runner without the channel.
  }
}

/// How long to wait before trimming.
///
/// Trimming while the window is still going away, or while startup is still
/// touching pages, only has them faulted straight back in. Long enough to be
/// past both, short enough that a user who opens the app and leaves it alone
/// sees the benefit.
const Duration windowsTrimDelay = Duration(seconds: 2);

/// The longer wait used at startup, where more is still settling - plugins
/// registering, the first history load, the tray icon going up.
const Duration windowsStartupTrimDelay = Duration(seconds: 8);
