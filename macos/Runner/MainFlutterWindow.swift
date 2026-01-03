import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Keep strong reference to prevent deallocation
  private var powerMonitor: PowerMonitor?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Enable transparency for tray menu window
    self.isOpaque = false
    self.backgroundColor = NSColor.clear
    self.hasShadow = true // Allow Flutter to control shadows

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Initialize power monitor for system sleep/wake/lock events
    powerMonitor = PowerMonitor(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
