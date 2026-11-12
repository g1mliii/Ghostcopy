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

  /// A push for desktop push (MacPushService), delivered while GhostCopy runs.
  /// The pushes are silent (content-available, no alert), and macOS hands a
  /// silent push to a running app only here. firebase_messaging is meant to
  /// receive this through its app-delegate proxy, but on macOS nothing reached
  /// Dart: the edge function sent the push and the app logged no arrival. So
  /// it is forwarded on GhostCopy's own channel instead.
  override func application(
    _ application: NSApplication,
    didReceiveRemoteNotification userInfo: [String: Any]
  ) {
    // No super: Swift demands `override` because FlutterAppDelegate adopts
    // NSApplicationDelegate, but it does not implement this method, and
    // calling super aborted the app (doesNotRecognizeSelector).
    (mainFlutterWindow as? MainFlutterWindow)?.forwardRemoteNotification(userInfo)
  }
}
