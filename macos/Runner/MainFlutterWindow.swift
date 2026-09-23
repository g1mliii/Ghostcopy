import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Keep strong reference to prevent deallocation
  private var appUpdater: AppUpdater?
  private var powerMonitor: PowerMonitor?
  private var shareService: ShareService?
  private var clipboardChangeCount: ClipboardChangeCount?
  private var launchAtStartup: LaunchAtStartup?

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

    super.awakeFromNib()
    
    // Ensure window is hidden at launch (prevents ghost window)
    // Flutter code (window_manager) will show it when ready
    self.orderOut(nil)
  }
}
