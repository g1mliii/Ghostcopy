import Flutter
import UIKit
import UserNotifications

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
    // No notification categories are registered, so notifications carry no
    // long-press actions.
    //
    // There used to be a Copy button that wrote the pasteboard without opening
    // the app. It depended on the clip already being on the device, staged by a
    // background isolate woken by a content-available push. That worked on
    // Android, where background execution is permissive, and could not be made
    // dependable here: iOS throttles background wake-ups on battery, Low Power
    // Mode and usage, and refuses them outright for an app the user swiped
    // away. The result was a button that copied instantly sometimes and did
    // nothing the rest of the time, with no way for the user to tell which -
    // worse than a tap that always behaves the same way.
    //
    // Tapping opens the app and copies, for text and files alike. On a phone
    // this fast that is a small price for one predictable behaviour.
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

  /// Handle a notification being acted on.
  ///
  /// There is only one action on iOS: tapping the notification. The long-press
  /// Copy/Dismiss/Details buttons were removed along with the background
  /// prefetch that made an instant copy possible - see the note in
  /// didFinishLaunchingWithOptions.
  ///
  /// The tap brings the app forward, which is what gives the Dart side the time
  /// and the foreground state it needs to fetch the clip, decrypt it, and then
  /// either write the pasteboard or open the share sheet. Everything that
  /// decides between those lives in processShareAction() in
  /// mobile_main_viewmodel.dart, so this hands off and does nothing else.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // Older builds registered a CLIPBOARD_SYNC category with Dismiss and
    // custom actions. Those notifications can still be on a user's device
    // after upgrading, and their dismissal also reaches this delegate. Only
    // the ordinary notification tap is a supported GhostCopy action; treating
    // every response as a tap would copy a clip the user explicitly dismissed.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      completionHandler()
      return
    }

    let userInfo = response.notification.request.content.userInfo
    let clipboardId = userInfo["clipboard_id"] as? String ?? ""

    if !clipboardId.isEmpty {
      FlutterChannelHub.shared.sendNotificationAction(clipboardId: clipboardId, action: "copy")
    }


    completionHandler()
  }

  /// Handle a notification arriving while the app is on screen.
  ///
  /// Nothing is presented. The app is already open and its realtime
  /// subscription brings the clip into history by itself, so a banner over
  /// GhostCopy would be announcing something the user can already see - and
  /// this app is built around sync that stays out of the way. The Android
  /// notification channel disables sound and vibration for the same reason.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

}
