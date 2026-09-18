import Flutter
import Foundation

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
  private static let notificationChannelName = "com.ghostcopy.ghostcopy/notifications"

  private var shareChannel: FlutterMethodChannel?
  private var notificationChannel: FlutterMethodChannel?

  /// A notification action that arrived before Flutter was ready.
  ///
  /// Tapping a notification for an app the user swiped away cold-launches it,
  /// and iOS calls didReceive long before the scene has built a
  /// FlutterViewController - so the engine, and therefore these channels, do
  /// not exist yet. Sending on a nil channel is a silent no-op, which would
  /// mean the one case this whole flow exists for - tap a notification, get the
  /// clip - quietly did nothing on a killed app.
  ///
  /// One slot, not a queue: each entry is "the clip the user just asked for",
  /// and if two arrive before the engine is up the newer tap is the one they
  /// meant.
  private var pendingNotificationAction: (clipboardId: String, action: String)?

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

    let notifications = FlutterMethodChannel(
      name: Self.notificationChannelName,
      binaryMessenger: messenger
    )
    notifications.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "takePendingNotificationAction":
        // Dart asks for this once its own handler is registered. Creating the
        // channel is not the same as Dart listening on it - the engine exists
        // well before main() has built the screen that answers - so the parked
        // tap is handed over on request rather than pushed and hoped for.
        guard let pending = self?.pendingNotificationAction else {
          result(nil)
          return
        }
        self?.pendingNotificationAction = nil
        print("[ChannelHub] Handing deferred tap for \(pending.clipboardId) to Dart")
        result(["clipboardId": pending.clipboardId, "action": pending.action])

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    notificationChannel = notifications
  }

  // MARK: - Outbound

  func sendSharedContent(_ content: String) {
    shareChannel?.invokeMethod("handleShareIntent", arguments: ["content": content])
  }

  func sendNotificationAction(clipboardId: String, action: String) {
    guard let notificationChannel = notificationChannel else {
      // Cold launch from a notification tap: hold it until attach() runs.
      pendingNotificationAction = (clipboardId: clipboardId, action: action)
      print("[ChannelHub] Engine not ready - deferring action for \(clipboardId)")
      return
    }

    notificationChannel.invokeMethod(
      "handleNotificationAction",
      arguments: ["clipboardId": clipboardId, "action": action]
    ) { result in
      if let error = result as? FlutterError {
        print("[ChannelHub] ⚠️ Notification action error: \(error.message ?? "unknown")")
      }
    }
  }
}
