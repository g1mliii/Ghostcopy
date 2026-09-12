import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ghost_toast.dart';

const _notificationChannel = MethodChannel(
  'com.ghostcopy.ghostcopy/notifications',
);

/// Show a short confirmation using the platform's own toast where one exists.
///
/// Brief confirmations like "Copied to clipboard" should look like the system,
/// not like the app - the custom in-app overlay reads as heavier than the
/// action deserves.
///
/// Android gets `android.widget.Toast`. iOS has no system toast at all - Apple
/// has never shipped an equivalent - so there it falls back to the in-app
/// toast, which is the closest thing available without inventing a banner.
Future<void> showNativeToast(
  BuildContext context,
  String message, {
  bool long = false,
  IconData icon = Icons.check_circle,
  GhostToastType type = GhostToastType.success,
}) async {
  if (Platform.isAndroid) {
    try {
      await _notificationChannel.invokeMethod<bool>('showNativeToast', {
        'message': message,
        'long': long,
      });
      return;
    } on PlatformException catch (e) {
      debugPrint('[NativeToast] Falling back to in-app toast: ${e.message}');
      // Fall through to the in-app toast below.
    } on MissingPluginException {
      // Channel not registered (e.g. a hot restart mid-development).
      debugPrint('[NativeToast] Channel unavailable, using in-app toast');
    }
  }

  if (context.mounted) {
    showGhostToast(context, message, icon: icon, type: type);
  }
}
