import Cocoa
import FlutterMacOS
import ServiceManagement

/// Backs the `launch_at_startup` package's method channel on macOS.
///
/// The package ships no macOS code of its own - it expects the app to answer
/// this channel. Nothing did, so every call threw MissingPluginException,
/// AutoStartService swallowed it, and the "Launch at startup" toggle saved
/// the preference without ever registering a login item.
///
/// SMAppService.mainApp registers the app bundle itself (macOS 13+), which is
/// what shows up under System Settings > General > Login Items. It cannot pass
/// launch arguments, so `--launched-at-startup` never arrives here; nothing
/// reads it, since the window starts hidden on every launch anyway.
class LaunchAtStartup {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "launch_at_startup",
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                // .requiresApproval means the user switched it off in Login
                // Items - it will not launch, so it is not enabled.
                result(SMAppService.mainApp.status == .enabled)
            case "launchAtStartupSetEnabled":
                let args = call.arguments as? [String: Any]
                let enable = args?["setEnabledValue"] as? Bool ?? false
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    result(nil)
                } catch {
                    result(FlutterError(
                        code: "LOGIN_ITEM_FAILED",
                        message: error.localizedDescription,
                        details: nil
                    ))
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }
}
