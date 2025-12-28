import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register notification categories with actions
    registerNotificationCategories()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  // Handle notification action response
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == "COPY_ACTION" {
      // Extract clipboard content from notification
      let clipboardContent = response.notification.request.content.userInfo["clipboard_content"] as? String ?? ""

      // Copy to clipboard
      UIPasteboard.general.string = clipboardContent

      // Optional: Show brief confirmation
      print("Copied to clipboard: \(clipboardContent.prefix(50))...")
    }

    completionHandler()
  }
}
