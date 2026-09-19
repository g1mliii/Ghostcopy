// Launch through LaunchServices, then verify this exact copy stays running.
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let bundleID = Bundle(url: url)!.bundleIdentifier!
if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
    fputs("Quit the running GhostCopy before testing the packaged copy.\n", stderr)
    exit(1)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
    guard let app = app, error == nil else {
        fputs("LaunchServices failed: \(String(describing: error))\n", stderr)
        exit(1)
    }
    guard app.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else {
        fputs("LaunchServices opened a different copy of the app.\n", stderr)
        exit(1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        guard !app.isTerminated else {
            fputs("GhostCopy exited within 12 seconds of launch.\n", stderr)
            exit(1)
        }
        print("LaunchServices smoke test passed: PID \(app.processIdentifier), \(url.path)")
        // Leave it open for visual inspection and manual functional checks.
        exit(0)
    }
}
RunLoop.main.run()
