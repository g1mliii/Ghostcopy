import Flutter
import UIKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let SHARE_CHANNEL = "com.ghostcopy.ghostcopy/share"
  private let WIDGET_CHANNEL = "com.ghostcopy.ghostcopy/widget"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register notification categories with actions
    registerNotificationCategories()

    // Set notification delegate for foreground handling
    UNUserNotificationCenter.current().delegate = self

    // Setup method channel for share intent handling
    setupShareMethodChannel()

    // Setup method channel for widget data updates
    setupWidgetMethodChannel()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func setupShareMethodChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let shareChannel = FlutterMethodChannel(
      name: SHARE_CHANNEL,
      binaryMessenger: controller.binaryMessenger
    )

    shareChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "shareComplete":
        // Share was processed, can do cleanup if needed
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setupWidgetMethodChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let widgetChannel = FlutterMethodChannel(
      name: WIDGET_CHANNEL,
      binaryMessenger: controller.binaryMessenger
    )

    widgetChannel.setMethodCallHandler { [weak self] (call, result) in
      switch call.method {
      case "updateWidget":
        // Called from Flutter when clipboard items are updated
        if let args = call.arguments as? [String: Any],
           let items = args["items"] as? [[String: Any]] {
          let dataManager = WidgetDataManager.shared
          dataManager.saveClipboardItems(items)

          // Reload widget
          if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
          }

          result(["success": true])
        } else {
          result(["success": false])
        }

      case "storeSupabaseCredentials":
        // Store credentials for widget to use during refresh
        if let args = call.arguments as? [String: Any],
           let url = args["url"] as? String,
           let key = args["anonKey"] as? String {
          UserDefaults.standard.set(url, forKey: "supabase_url")
          UserDefaults.standard.set(key, forKey: "supabase_anon_key")
          UserDefaults.standard.synchronize()
          result(["success": true])
        } else {
          result(["success": false])
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Handle app opened via share intent or widget deep link
  override func application(
    _ application: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Check if opened via share action
    if url.scheme == "com.ghostcopy.share" {
      if let sharedText = url.host {
        notifyFlutterOfSharedContent(sharedText)
      }
    }

    // Check if opened via widget tap (ghostcopy://copy/{clipboard_id})
    if url.scheme == "ghostcopy" && url.host == "copy" {
      // Extract clipboard ID from path
      let clipboardId = url.lastPathComponent
      print("[AppDelegate] 📋 Widget deep link: copy clipboard \(clipboardId)")
      notifyFlutterOfWidgetAction(clipboardId)
    }

    return super.application(application, open: url, options: options)
  }

  private func registerNotificationCategories() {
    // Define "Copy to Clipboard" action
    let copyAction = UNNotificationAction(
      identifier: "COPY_ACTION",
      title: "Copy to Clipboard",
      options: [.foreground] // Opens app briefly
    )

    // Define category with copy action
    let clipboardCategory = UNNotificationCategory(
      identifier: "CLIPBOARD_SYNC",
      actions: [copyAction],
      intentIdentifiers: [],
      options: []
    )

    // Register category
    UNUserNotificationCenter.current().setNotificationCategories([clipboardCategory])
  }

  private func notifyFlutterOfSharedContent(_ content: String) {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let shareChannel = FlutterMethodChannel(
      name: SHARE_CHANNEL,
      binaryMessenger: controller.binaryMessenger
    )

    shareChannel.invokeMethod("handleShareIntent", arguments: ["content": content]) { result in
      // Share processing complete, close the share extension
      // The app was launched via share intent and will handle device selection in Flutter
    }
  }

  private func notifyFlutterOfWidgetAction(_ clipboardId: String) {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let widgetChannel = FlutterMethodChannel(
      name: WIDGET_CHANNEL,
      binaryMessenger: controller.binaryMessenger
    )

    widgetChannel.invokeMethod("handleWidgetAction", arguments: ["clipboardId": clipboardId]) { [weak self] result in
      // Widget action handled - app will navigate to clipboard details if needed
    }
  }

  // Handle notification action response (when user taps action button or notification)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo

    // Extract clipboard content from FCM data payload
    let clipboardContent = userInfo["clipboard_content"] as? String ?? ""
    let deviceType = userInfo["device_type"] as? String ?? "Another device"

    // Handle copy action (from action button)
    if response.actionIdentifier == "COPY_ACTION" {
      if !clipboardContent.isEmpty {
        UIPasteboard.general.string = clipboardContent
        print("✅ Copied to clipboard from \(deviceType)")
      }
    }

    // Handle default action (notification tap)
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
      if !clipboardContent.isEmpty {
        UIPasteboard.general.string = clipboardContent
        print("✅ Copied to clipboard from \(deviceType) (tap)")
      }
    }

    // Update widget with new clipboard item
    updateWidgetForFCMNotification(userInfo)

    completionHandler()
  }

  // Handle foreground notifications (when app is active)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo

    // Extract clipboard content from FCM data payload
    let clipboardContent = userInfo["clipboard_content"] as? String ?? ""
    let deviceType = userInfo["device_type"] as? String ?? "Another device"

    print("📱 FCM notification received in foreground from \(deviceType)")

    if !clipboardContent.isEmpty {
      // Auto-copy when app is in foreground
      UIPasteboard.general.string = clipboardContent
      print("✅ Auto-copied to clipboard: \(clipboardContent.prefix(50))...")
    }

    // Update widget with new clipboard item
    updateWidgetForFCMNotification(userInfo)

    // Show notification banner and sound (optional)
    completionHandler([.banner, .badge, .sound])
  }

  // MARK: - Widget Update Methods

  /// Update widget when FCM notification arrives
  /// Adds new item to widget storage and reloads widget timeline
  private func updateWidgetForFCMNotification(_ userInfo: [AnyHashable: Any]) {
    // Extract item data from FCM payload
    guard let clipboardContent = userInfo["clipboard_content"] as? String,
          !clipboardContent.isEmpty else {
      return
    }

    let contentType = (userInfo["content_type"] as? String) ?? "text"
    let contentPreview = (userInfo["content_preview"] as? String) ?? clipboardContent
    let deviceType = (userInfo["device_type"] as? String) ?? "Another device"
    let clipboardId = (userInfo["clipboard_id"] as? String) ?? UUID().uuidString

    // Create item dictionary for widget
    let item: [String: Any] = [
      "id": clipboardId,
      "contentType": contentType,
      "contentPreview": contentPreview,
      "thumbnailPath": userInfo["thumbnail_path"],
      "deviceType": deviceType,
      "createdAt": Date().toISO8601String(),
      "isEncrypted": (userInfo["is_encrypted"] as? Bool) ?? false,
    ]

    // Add to widget storage
    let dataManager = WidgetDataManager.shared
    dataManager.addNewClip(item)

    print("[AppDelegate] ✅ Widget updated with FCM notification")
  }
}

extension Date {
  func toISO8601String() -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: self)
  }
}
