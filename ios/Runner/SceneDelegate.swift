import Flutter
import UIKit

/// Scene delegate for the app's single window scene.
///
/// Building against the iOS 27 SDK makes the UIScene life cycle mandatory - an
/// app without it is refused at launch with "UIScene life cycle is required for
/// apps built with this SDK" and shows nothing but a white screen. Flutter
/// supplies `FlutterSceneDelegate`, which does all the engine and window setup;
/// this subclass only adds what GhostCopy needs on top.
///
/// Two responsibilities moved here from AppDelegate, because both are
/// scene-scoped under the new life cycle and no longer arrive on the app
/// delegate at all:
///   - the privacy blur, previously applicationWillResignActive / DidBecomeActive
///   - deep links, previously application(_:open:options:)
@objc class SceneDelegate: FlutterSceneDelegate {
  private var blurView: UIVisualEffectView?

  // MARK: - Privacy blur

  /// Whether the user wants the app switcher preview hidden.
  ///
  /// The same "screenshot_protection" preference Android reads for FLAG_SECURE.
  /// shared_preferences namespaces its keys with "flutter." and writes them to
  /// NSUserDefaults, so the value is readable here without a channel call.
  ///
  /// Defaults to true, matching SettingsService.getScreenshotProtection(): a
  /// clipboard history is worth covering by default, so opting out is the
  /// deliberate act.
  private var hidesAppSwitcherPreview: Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: "flutter.screenshot_protection") != nil else {
      return true
    }
    return defaults.bool(forKey: "flutter.screenshot_protection")
  }

  /// Cover the window while the app is off-screen, so the task switcher
  /// snapshot does not leak clipboard contents.
  ///
  /// Only when the user asks for it. This used to be unconditional, and the
  /// toggle that turns it off was shown on Android only - so an iOS user had
  /// a blurred card in the app switcher, unlike almost everything else on the
  /// phone, and no way to change it.
  override func sceneWillResignActive(_ scene: UIScene) {
    if hidesAppSwitcherPreview, let window = window, blurView == nil {
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.frame = window.bounds
      blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.addSubview(blur)
      blurView = blur
    }
    super.sceneWillResignActive(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    blurView?.removeFromSuperview()
    blurView = nil
    super.sceneDidBecomeActive(scene)
  }

  // MARK: - Deep links

  /// Handles links opened while the app is already running.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      handle(url: context.url)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  /// Handles a link that launched the app from cold. `connectionOptions`
  /// carries the URL in that case - `openURLContexts` is never called for it.
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for context in connectionOptions.urlContexts {
      handle(url: context.url)
    }
  }

  private func handle(url: URL) {
    // com.ghostcopy.share://<text> is gone with the hand-rolled share path;
    // receive_sharing_intent's extension owns the share sheet now and calls
    // back on ShareMedia-<bundle id>, which the plugin handles itself.
    guard url.scheme == "ghostcopy" else { return }

    // ghostcopy://copy/<id> and ghostcopy://share/<id> were the home screen
    // widget's two taps and went with it. The scheme itself stays - Supabase
    // uses it for OAuth and password reset.
  }
}
