import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Prevent app from quitting when window closes - app runs in system tray
  /// This allows GhostCopy to stay running in the background (tray mode)
  /// and respond to global hotkeys even when the Spotlight window is hidden
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Check and prompt for Accessibility permissions (needed for global hotkeys)
    // This will show the system permission dialog if not already granted
    checkAccessibilityPermissions()
  }

  /// Check if Accessibility permissions are granted, prompt if not
  private func checkAccessibilityPermissions() {
    // Create options dictionary to show the system prompt
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    let accessEnabled = AXIsProcessTrustedWithOptions(options)

    if accessEnabled {
      print("[AppDelegate] ✅ Accessibility permissions granted")
    } else {
      print("[AppDelegate] ⚠️ Accessibility permissions not granted - system prompt shown")
    }
  }
}
