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
}
