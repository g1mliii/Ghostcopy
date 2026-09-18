import Cocoa
import FlutterMacOS

/// Backs the "Send with GhostCopy" entry in Finder's context menu.
///
/// This is the macOS counterpart to the Windows Explorer context menu. Windows
/// registers a shell command that relaunches the app with --send-file; macOS
/// has no equivalent hook, so the request arrives here as a Service and is
/// forwarded into the running app over a method channel.
///
/// A Share extension was tried first and worked, but it sits one submenu
/// deeper than the Service and offered nothing the Service does not.
class ShareService: NSObject {
    private let channel: FlutterMethodChannel
    private var flutterReady = false

    /// A Service can fire while the app is still starting, since macOS
    /// launches the app to deliver the request. Those paths are replayed once
    /// Dart says it is listening.
    private var pendingPaths: [String] = []

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "com.ghostcopy.app/share",
            binaryMessenger: messenger
        )
        super.init()

        channel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }
            if call.method == "ready" {
                self.flutterReady = true
                let paths = self.pendingPaths
                self.pendingPaths = []
                result(paths)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        NSApplication.shared.servicesProvider = self
    }

    /// Declared as NSMessage in Info.plist; the selector name must match it.
    ///
    /// Runs inside the app, so the paths go straight to Dart - the file access
    /// comes from the user-selected entitlement.
    @objc func sendFileWithGhostCopy(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL] ?? []

        let paths = urls.filter { $0.isFileURL }.map { $0.path }
        guard !paths.isEmpty else {
            error.pointee = "No file was provided." as NSString
            return
        }

        if flutterReady {
            channel.invokeMethod("sendFiles", arguments: paths)
        } else {
            pendingPaths.append(contentsOf: paths)
        }
    }
}
