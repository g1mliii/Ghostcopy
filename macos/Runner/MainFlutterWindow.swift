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
    appPresence = AppPresence(
      messenger: flutterViewController.engine.binaryMessenger,
      spotlight: self
    )

    super.awakeFromNib()
    
    // Ensure window is hidden at launch (prevents ghost window)
    // Flutter code (window_manager) will show it when ready
    self.orderOut(nil)
  }
}

/// Puts GhostCopy in the Dock and Cmd-Tab while an ordinary pin holds the
/// Spotlight up as a normal window, and takes it out again after. Dart says
/// which it wants (setInAppSwitcher); this owns making it so.
///
/// In this file rather than its own so the Xcode project does not change.
///
/// Leaving is the delicate half: macOS does not apply the accessory policy
/// to the active app (see LSUIElement in Info.plist). When the Spotlight has
/// gone, focus is handed back first; when it is still up (the pin went to
/// on-top), it is left in front. Either way, a switch that did not take is
/// applied again the moment GhostCopy stops being the active app.
class AppPresence {
    private let channel: FlutterMethodChannel
    private weak var spotlight: NSWindow?
    private var wanted = false
    private var resignObserver: NSObjectProtocol?

    init(messenger: FlutterBinaryMessenger, spotlight: NSWindow) {
        self.spotlight = spotlight
        channel = FlutterMethodChannel(
            name: "com.ghostcopy/app_presence",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { [weak self] (call, result) in
            guard call.method == "setInAppSwitcher",
                  let wanted = call.arguments as? Bool else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.set(inSwitcher: wanted)
            result(nil)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.settle() }
    }

    private func set(inSwitcher: Bool) {
        wanted = inSwitcher
        if inSwitcher {
            NSApp.setActivationPolicy(.regular)
            return
        }
        // Next turn of the main queue: window_manager's hide() orders the
        // window out asynchronously, and that has to have happened before
        // asking whether the Spotlight is still up.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.wanted else { return }
            if NSApp.isActive && !(self.spotlight?.isVisible ?? false) {
                NSApp.deactivate()
            }
            self.settle()
        }
    }

    /// Out of the switcher, if that is what Dart last asked for and it has
    /// not happened yet.
    private func settle() {
        guard !wanted, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
