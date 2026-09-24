import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// Let file_picker open panels in the unsandboxed macOS app.
///
/// The plugin refuses to show an open or save panel unless the app holds
/// com.apple.security.files.user-selected.read-only or read-write. Those are
/// App Sandbox permissions and went with the sandbox, so from macOS build 5
/// Attach in the Spotlight failed with "Failed to load file:
/// PlatformException(ENTITLEMENT_NOT_FOUND ...)" and Save as failed the same
/// way. Outside the sandbox the panels need no entitlement, and this is the
/// plugin's own switch for that case. Nothing else checks it: it guards no
/// access, it only warns sandboxed apps that forgot the entitlement.
///
/// Must run before the first panel opens; main() calls it at startup.
Future<void> prepareFilePicker({required bool isMacOS}) async {
  if (!isMacOS) return;
  try {
    await FilePicker.skipEntitlementsChecks();
  } on Object catch (e) {
    debugPrint('[FilePicker] Could not skip the entitlement check: $e');
  }
}
