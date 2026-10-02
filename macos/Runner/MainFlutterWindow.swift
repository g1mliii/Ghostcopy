import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Keep strong reference to prevent deallocation
  private var appUpdater: AppUpdater?
  private var powerMonitor: PowerMonitor?
  private var shareService: ShareService?
  private var clipboardChangeCount: ClipboardChangeCount?
  private var launchAtStartup: LaunchAtStartup?
  private var appPresence: AppPresence?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    flutterViewController.backgroundColor = .clear // Ensure Flutter view is transparent
    self.setFrame(windowFrame, display: false)

    // Enable transparency for tray menu window
    self.isOpaque = false
    self.backgroundColor = NSColor.clear
    self.hasShadow = true // Allow Flutter to control shadows

    RegisterGeneratedPlugins(registry: flutterViewController)

    appUpdater = AppUpdater(messenger: flutterViewController.engine.binaryMessenger)

    // Initialize power monitor for system sleep/wake/lock events
    powerMonitor = PowerMonitor(messenger: flutterViewController.engine.binaryMessenger)

    // Backs the Finder Services entry ("Send with GhostCopy")
    shareService = ShareService(messenger: flutterViewController.engine.binaryMessenger)

    // Lets the auto-send monitor skip reading an unchanged clipboard
    clipboardChangeCount = ClipboardChangeCount(messenger: flutterViewController.engine.binaryMessenger)

    // Answers the launch_at_startup package, which has no macOS code of its own
    launchAtStartup = LaunchAtStartup(messenger: flutterViewController.engine.binaryMessenger)

    // Dock and Cmd-Tab while an ordinary pin holds the Spotlight up
    appPresence = AppPresence(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
    
    // Ensure window is hidden at launch (prevents ghost window)
    // Flutter code (window_manager) will show it when ready
    self.orderOut(nil)
  }
}

/// Puts GhostCopy in the Dock and Cmd-Tab while an ordinary pin holds the
/// Spotlight up as a normal window, and takes it out again after.
///
/// In this file rather than its own so the Xcode project does not change.
///
/// Leaving is the delicate half. The Spotlight hides with orderOut, which
/// leaves GhostCopy the active app, and macOS does not apply the accessory
/// policy to the active app (see LSUIElement in Info.plist) - a Dock icon
/// and a Cmd-Tab entry for a window that is gone. So focus goes back to the
/// previous app first, and the policy changes once it has.
class AppPresence {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.ghostcopy/app_presence",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "enterAppSwitcher":
                NSApp.setActivationPolicy(.regular)
                result(nil)
            case "leaveAppSwitcher":
                AppPresence.leave { result(nil) }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func leave(then done: @escaping () -> Void) {
        if NSApp.isActive { NSApp.deactivate() }
        // A turn of the run loop for the deactivation to land. If it did not
        // (nothing else to activate), hiding the app hands focus on for sure;
        // the next show activates it, which unhides it.
        DispatchQueue.main.async {
            if NSApp.isActive { NSApp.hide(nil) }
            NSApp.setActivationPolicy(.accessory)
            done()
        }
    }
}

