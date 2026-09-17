import Flutter
import Foundation
import WidgetKit

/// Owns the app's platform channels.
///
/// These used to be built on demand from `window?.rootViewController as?
/// FlutterViewController`. That does not survive the UIScene life cycle - the
/// app delegate no longer owns a window - and it was fragile even before:
/// every call site began with a `guard let ... else { return }`, so a
/// notification or deep link arriving before the root view controller existed
/// was dropped silently.
///
/// The channels are now built once, from the engine's own binary messenger, as
/// soon as the implicit engine is initialized. They outlive any particular view
/// controller and are reachable from both AppDelegate and SceneDelegate.
final class FlutterChannelHub {
  static let shared = FlutterChannelHub()

  private static let shareChannelName = "com.ghostcopy.ghostcopy/share"
  private static let widgetChannelName = "com.ghostcopy/widget"
  private static let notificationChannelName = "com.ghostcopy.ghostcopy/notifications"

  private var shareChannel: FlutterMethodChannel?
  private var widgetChannel: FlutterMethodChannel?
  private var notificationChannel: FlutterMethodChannel?

  private init() {}

  /// Builds the channels against the engine's messenger. Called once, from
  /// AppDelegate's `didInitializeImplicitFlutterEngine`.
  func attach(messenger: FlutterBinaryMessenger) {
    let share = FlutterMethodChannel(name: Self.shareChannelName, binaryMessenger: messenger)
    share.setMethodCallHandler { (call, result) in
      switch call.method {
      case "shareComplete":
        // Share was processed; nothing to clean up on the native side.
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    shareChannel = share

    let widget = FlutterMethodChannel(name: Self.widgetChannelName, binaryMessenger: messenger)
    widget.setMethodCallHandler { (call, result) in
      switch call.method {
      case "updateWidget":
        guard let args = call.arguments as? [String: Any],
          let items = args["items"] as? [[String: Any]]
        else {
          result(["success": false])
          return
        }
        WidgetDataManager.shared.saveClipboardItems(items)
        WidgetCenter.shared.reloadAllTimelines()
        result(["success": true])

      case "storeSupabaseCredentials":
        guard let args = call.arguments as? [String: Any],
          let url = args["url"] as? String,
          let key = args["anonKey"] as? String
        else {
          result(["success": false])
          return
        }
        WidgetDataManager.shared.storeSupabaseCredentials(url: url, anonKey: key)
        result(["success": true])

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    widgetChannel = widget

    notificationChannel = FlutterMethodChannel(
      name: Self.notificationChannelName,
      binaryMessenger: messenger
    )
  }

  // MARK: - Outbound

  func sendSharedContent(_ content: String) {
    shareChannel?.invokeMethod("handleShareIntent", arguments: ["content": content])
  }

  func sendWidgetAction(clipboardId: String) {
    widgetChannel?.invokeMethod("handleWidgetAction", arguments: ["clipboardId": clipboardId])
  }

  func sendNotificationAction(clipboardId: String, action: String) {
    notificationChannel?.invokeMethod(
      "handleNotificationAction",
      arguments: ["clipboardId": clipboardId, "action": action]
    ) { result in
      if let error = result as? FlutterError {
        print("[ChannelHub] ⚠️ Notification action error: \(error.message ?? "unknown")")
      }
    }
  }
}
