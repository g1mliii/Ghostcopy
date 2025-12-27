import Cocoa
import FlutterMacOS

/// Monitors system power events on macOS
/// Listens to NSWorkspace notifications for sleep/wake/lock/unlock
class PowerMonitor {
    private let channel: FlutterMethodChannel
    private var workspaceObservers: [NSObjectProtocol] = []

    init(messenger: FlutterBinaryMessenger) {
        // Create method channel
        channel = FlutterMethodChannel(
            name: "com.ghostcopy.app/power",
            binaryMessenger: messenger
        )

        // Handle method calls from Flutter
        channel.setMethodCallHandler { [weak self] (call, result) in
            if call.method == "startListening" {
                self?.startListening()
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func startListening() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        // Listen for sleep notification
        let sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendEvent("willSleep")
        }
        workspaceObservers.append(sleepObserver)

        // Listen for wake notification
        let wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendEvent("didWake")
        }
        workspaceObservers.append(wakeObserver)

        // Listen for screen lock notification
        let lockObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendEvent("screensDidLock")
        }
        workspaceObservers.append(lockObserver)

        // Listen for screen unlock notification
        let unlockObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendEvent("screensDidUnlock")
        }
        workspaceObservers.append(unlockObserver)
    }

    private func sendEvent(_ eventName: String) {
        channel.invokeMethod(eventName, arguments: nil)
    }

    deinit {
        // Clean up observers to prevent memory leaks
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }
}
