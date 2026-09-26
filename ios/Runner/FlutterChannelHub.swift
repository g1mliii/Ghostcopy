import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    ImageTranscoder.attach(messenger: messenger)
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
    ) { [weak self] result in
      if let error = result as? FlutterError {
        print("[ChannelHub] ⚠️ Notification action error: \(error.message ?? "unknown")")
        return
      }

      // Dart reports a failed action by COMPLETING with false, not by
      // erroring - a clip it could not fetch, decrypt or download comes back
      // that way. Only FlutterError was inspected here, so the warm path threw
      // the tap away in silence: no copy, no sheet, nothing said, and nothing
      // kept. The deferred path already surfaces this; its live twin did not.
      //
      // Parked rather than reported, because there is no UI to report from
      // here - and parking means the next drain retries it, which is the
      // better outcome anyway.
      if let handled = result as? Bool, handled == false {
        self?.pendingNotificationAction = (clipboardId: clipboardId, action: action)
        print("[ChannelHub] Dart could not handle \(clipboardId) - parked for retry")
      }
    }
  }
}

/// HEIC to JPEG through ImageIO, for `lib/services/image_transcoder.dart`.
///
/// iPhone photos are HEIC by default, which the Dart `image` package cannot
/// decode, so without this they went as plain files - no preview, unopenable
/// on most Windows machines, and refused over the size limit.
enum ImageTranscoder {
  private static let channelName = "com.ghostcopy/image_transcoder"
  private static let maxSide = 4096
  private static let minSide = 1024
  private static let quality = 0.85

  static func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "toJpeg" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let maxBytes = args["maxBytes"] as? Int else {
        result(FlutterError(code: "INVALID_ARGS", message: "path and maxBytes are required", details: nil))
        return
      }
      // A 48 MP photo takes a noticeable moment; keep it off the main thread.
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = toJpeg(path: path, maxBytes: maxBytes)
        DispatchQueue.main.async {
          result(jpeg.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    }
  }

  /// Halves the longest side from [maxSide] until the JPEG fits, as
  /// shrinkImageToFit does in Dart. ImageIO decodes straight to the target
  /// size, so the full-resolution image is never held in memory.
  private static func toJpeg(path: String, maxBytes: Int) -> Data? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int,
          let height = props[kCGImagePropertyPixelHeight] as? Int else {
      return nil
    }
    var side = min(maxSide, max(width, height))
    while side >= min(minSide, max(width, height)) {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
        // Applies the EXIF orientation, which the JPEG would not carry over.
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        data, UTType.jpeg.identifier as CFString, 1, nil
      ) else { return nil }
      // No source properties are copied, so location and the rest of the
      // metadata stay behind.
      CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: quality,
      ] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      if data.length <= maxBytes { return data as Data }
      side /= 2
    }
    return nil
  }
}
