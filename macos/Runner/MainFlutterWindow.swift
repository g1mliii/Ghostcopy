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

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Initialize power monitor for system sleep/wake/lock events
    if let messenger = flutterViewController.engine.binaryMessenger {
      powerMonitor = PowerMonitor(messenger: messenger)
    }

    super.awakeFromNib()
  }
}
