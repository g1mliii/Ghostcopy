import Flutter
import UIKit
import UserNotifications
import WidgetKit

/// Application delegate.
///
/// Under the UIScene life cycle (mandatory when building against the iOS 27
/// SDK) this object no longer owns a window, and no longer sees scene-scoped
/// events. The privacy blur and deep-link handling moved to SceneDelegate;
/// what remains here is genuinely app-scoped: plugin registration and
/// notification handling.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register notification categories with actions
    ActionableNotificationManager.shared.registerCategories()

    // Set notification delegate for foreground handling
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Called once the implicit FlutterEngine exists. This - not
  /// didFinishLaunchingWithOptions - is where plugins register under the scene
  /// life cycle, and it is also the earliest point at which a binary messenger
  /// is available for the app's own channels.
  func didInitializeImplicitFlutterEngine(_ engineBridge: any FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    FlutterChannelHub.shared.attach(messenger: engineBridge.applicationRegistrar.messenger())
  }

  // MARK: - Notifications

  /// Handle notification action response (action button or notification tap).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let actionName = ActionableNotificationManager.shared.getActionName(response.actionIdentifier)

    print("[Notification] 📬 Action: \(actionName)")

    // Extract clipboard content from FCM data payload
    let clipboardContent = userInfo["clipboard_content"] as? String ?? ""
    let clipboardId = userInfo["clipboard_id"] as? String ?? ""
    let deviceType = userInfo["device_type"] as? String ?? "Another device"

    let notificationManager = ActionableNotificationManager.shared

    // Handle copy action (from action button or long-press menu)
    if notificationManager.isCopyAction(response.actionIdentifier) {
      copyClip(userInfoContent: clipboardContent, clipboardId: clipboardId, deviceType: deviceType)
    }

    // Handle dismiss action
    if notificationManager.isDismissAction(response.actionIdentifier) {
      print("👋 Notification dismissed")
    }

    // Handle details action
    if notificationManager.isDetailsAction(response.actionIdentifier) {
      if !clipboardId.isEmpty {
        FlutterChannelHub.shared.sendNotificationAction(clipboardId: clipboardId, action: "details")
      }
      print("📖 Opening clipboard item details")
    }

    // Handle default action (notification tap). The tap foregrounds the app
    // regardless, so the in-app fallback can finish the job if the prefetch
    // lost its race - but copying here still saves the user a round trip
    // through the UI whenever the clip was staged in time.
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      copyClip(userInfoContent: clipboardContent, clipboardId: clipboardId, deviceType: deviceType)
    }

    // Update widget with new clipboard item
    updateWidgetForFCMNotification(userInfo)

    completionHandler()
  }

  /// Handle foreground notifications (when app is active).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo

    // Extract clipboard content from FCM data payload
    let clipboardContent = userInfo["clipboard_content"] as? String ?? ""
    let contentType = userInfo["content_type"] as? String ?? "text"
    let deviceType = userInfo["device_type"] as? String ?? "Another device"

    print("📱 FCM notification received in foreground from \(deviceType)")

    // Check if this is a file/image
    let isFile = contentType.hasPrefix("file_")
    let isImage = contentType.hasPrefix("image_")

    if !clipboardContent.isEmpty && !isFile && !isImage {
      // Auto-copy text content when app is in foreground
      // Files/images cannot be auto-copied - user must tap notification
      UIPasteboard.general.string = clipboardContent
      print("✅ Auto-copied to clipboard: \(clipboardContent.prefix(50))...")
    } else if isFile || isImage {
      print("📎 File/image notification - user must tap to download and share")
    }

    // Update widget with new clipboard item
    updateWidgetForFCMNotification(userInfo)

    // Foreground presentation, decided by whether anything is left to do.
    //
    // Text was just auto-copied above, and the user is already looking at the
    // app - a system banner over GhostCopy announcing a clip that is already
    // on the pasteboard is pure noise, and it contradicts the invisible sync
    // this app is built around (the Android channel disables sound and
    // vibration for the same reason).
    //
    // A file or image is different: it was NOT copied, because it cannot be.
    // The user has to act on it, so the banner is the only thing telling them
    // it arrived, and it stays.
    let autoCopied = !clipboardContent.isEmpty && !isFile && !isImage
    completionHandler(autoCopied ? [] : [.banner, .badge, .sound])
  }


  /// Put a clip on the pasteboard, preferring the staged plaintext.
  ///
  /// Order matters. The push carries no clipboard value in production - the
  /// backend sends only an id - so `pending_copy.json`, written by the Dart
  /// background isolate, is the real source. The userInfo value is still
  /// honoured first because it costs nothing and covers any caller that does
  /// inline the content.
  ///
  /// Falling through to Flutter is the Android behaviour too: when nothing was
  /// staged, the app is asked to fetch it. That needs the engine, so it only
  /// completes for a notification tap, which foregrounds the app anyway.
  private func copyClip(userInfoContent: String, clipboardId: String, deviceType: String) {
    if !userInfoContent.isEmpty {
      UIPasteboard.general.string = userInfoContent
      print("✅ Copied to clipboard from \(deviceType) (inline)")
      return
    }

    if let staged = PendingCopyStore.take(),
      PendingCopyStore.isCopyableText(staged.contentType) {
      UIPasteboard.general.string = staged.content
      print("✅ Copied to clipboard from \(deviceType) (staged clip \(staged.id))")
      return
    }

    guard !clipboardId.isEmpty else { return }
    print("↩️ Nothing staged for \(clipboardId) - handing off to the app")
    FlutterChannelHub.shared.sendNotificationAction(clipboardId: clipboardId, action: "copy")
  }

  // MARK: - Widget Update Methods

  /// Update widget when FCM notification arrives.
  /// Adds new item to widget storage and reloads widget timeline.
  private func updateWidgetForFCMNotification(_ userInfo: [AnyHashable: Any]) {
    // Extract item data from FCM payload
    let clipboardContent = userInfo["clipboard_content"] as? String ?? ""
    let contentType = (userInfo["content_type"] as? String) ?? "text"
    let deviceType = (userInfo["device_type"] as? String) ?? "Another device"
    let clipboardId = (userInfo["clipboard_id"] as? String) ?? UUID().uuidString
    let fileSize = userInfo["file_size"] as? String
    let filename = userInfo["filename"] as? String

    // Determine if this is a file/image
    let isFile = contentType.hasPrefix("file_")
    let isImage = contentType.hasPrefix("image_")

    // Generate appropriate preview
    var contentPreview: String
    if isFile, let fname = filename {
      contentPreview = fname
    } else if isImage, let size = fileSize {
      contentPreview = "Image (\(size))"
    } else {
      contentPreview = clipboardContent.isEmpty ? "Content" : String(clipboardContent.prefix(100))
    }

    // Create item dictionary for widget
    let item: [String: Any] = [
      "id": clipboardId,
      "contentType": contentType,
      "contentPreview": contentPreview,
      "thumbnailPath": userInfo["thumbnail_path"] ?? "",
      "deviceType": deviceType,
      "createdAt": Date().toISO8601String(),
      "isEncrypted": (userInfo["is_encrypted"] as? Bool) ?? false,
      "isFile": isFile,
      "isImage": isImage,
      "displaySize": fileSize ?? "",
      "filename": filename ?? "",
    ]

    // Add to widget storage
    WidgetDataManager.shared.addNewClip(item)

    print("[AppDelegate] ✅ Widget updated with FCM notification (isFile=\(isFile), isImage=\(isImage))")
  }
}

extension Date {
  func toISO8601String() -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: self)
  }
}
