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

  private static let notificationChannelName = "com.ghostcopy.ghostcopy/notifications"

  private var notificationChannel: FlutterMethodChannel?

  /// Whether Dart currently has a handler on the notification channel.
  ///
  /// Not the same question as whether `notificationChannel` exists, which is
  /// what this used to test. The engine - and so the channel - is built during
  /// launch, well before main() has run far enough to build the screen that
  /// answers, and on a cold launch from a notification tap iOS calls didReceive
  /// inside that window. Testing the channel meant taking the invoke path with
  /// nobody on the other end, so the parked-tap fallback below was bypassed in
  /// precisely the case it exists for.
  private var isDartListening = false

  /// A notification action that arrived before Flutter was ready.
  ///
  /// Tapping a notification for an app the user swiped away cold-launches it,
  /// and iOS calls didReceive long before main() has built the screen that
  /// answers. The channel itself is usually up by then - it is built with the
  /// engine during launch - so the thing that is missing is a handler on the
  /// Dart end, not the channel. Either way an invoke lands on nobody, which
  /// would mean the one case this whole flow exists for - tap a notification,
  /// get the clip - quietly did nothing on a killed app.
  ///
  /// One slot, not a queue: each entry is "the clip the user just asked for",
  /// and if two arrive before the engine is up the newer tap is the one they
  /// meant.
  private var pendingNotificationAction: (clipboardId: String, action: String)?

  private init() {}

  /// Builds the channels against the engine's messenger. Called once, from
  /// AppDelegate's `didInitializeImplicitFlutterEngine`.
  func attach(messenger: FlutterBinaryMessenger) {
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
        //
        // This call is also the readiness signal: Dart makes it immediately
        // after setMethodCallHandler and nowhere else, so its arrival is proof
        // a push would now land.
        self?.isDartListening = true
        guard let pending = self?.pendingNotificationAction else {
          result(nil)
          return
        }
        self?.pendingNotificationAction = nil
        print("[ChannelHub] Handing deferred tap for \(pending.clipboardId) to Dart")
        result(["clipboardId": pending.clipboardId, "action": pending.action])

      case "notificationHandlerDetached":
        // The screen holding the handler was disposed - on sign-out, say. It
        // clears its handler, so anything invoked from here would land on
        // nobody; park instead until the next screen pulls.
        self?.isDartListening = false
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    notificationChannel = notifications
  }

  // MARK: - Outbound

  func sendNotificationAction(clipboardId: String, action: String) {
    guard isDartListening, let notificationChannel = notificationChannel else {
      // Cold launch from a notification tap, or the screen is between builds:
      // hold it until Dart next pulls.
      pendingNotificationAction = (clipboardId: clipboardId, action: action)
      print("[ChannelHub] Dart not listening - deferring action for \(clipboardId)")
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
