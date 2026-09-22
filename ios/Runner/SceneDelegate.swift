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
  /// Defaults to false, matching SettingsService.getScreenshotProtection().
  /// It is the user's own device; an ordinary app switcher preview is theirs
  /// to have. Anyone who wants the cover can turn it on.
  ///
  /// The two defaults have to agree. This one decides what happens before Dart
  /// has run, and a mismatch would blur a window whose own toggle says it
  /// should not be blurred.
  private var hidesAppSwitcherPreview: Bool {
    UserDefaults.standard.bool(forKey: "flutter.screenshot_protection")
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
  //
  // Nothing to override. Both URL schemes this app answers are handled by
  // plugins on the Flutter side: ghostcopy:// is Supabase's OAuth and
  // password-reset callback, and ShareMedia-<bundle id> belongs to
  // receive_sharing_intent, whose extension owns the share sheet.
  //
  // There used to be a handle(url:) here with openURLContexts and willConnectTo
  // overrides feeding it. It became a guard and two comments once the hand-rolled
  // com.ghostcopy.share:// path and the widget's ghostcopy://copy/<id> and
  // ghostcopy://share/<id> taps were removed with the home screen widget - three
  // methods implementing a no-op, and a plausible-looking place for the next
  // person to add a deep link and wonder why it never fires.
}
