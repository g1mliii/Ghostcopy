import Cocoa
import FlutterMacOS
import Sentry
import Sparkle

/// Owns one Sparkle session for the lifetime of this menu bar application.
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
  private let channel: FlutterMethodChannel
  private var updateAvailable = false
  private var started = false
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
  )

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.ghostcopy/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "initialize":
          #if DEBUG
          // A development checkout must never replace itself with a release.
          result(FlutterError(code: "development_build", message: "Updates are available in installed release builds.", details: nil))
          #else
          if !self.started {
            try self.controller.updater.start()
            self.started = true
          }
          result(self.state)
          #endif
        case "checkForUpdates":
          guard self.started else {
            result(FlutterError(code: "not_started", message: "The updater is not available in this build.", details: nil))
            return
          }
          // Come forward first. This is an LSUIElement agent: no Dock icon, no
          // menu bar, and it is not the frontmost app when the user picks
          // "Check for Updates..." from the tray. Sparkle's window would open
          // behind whatever they were using, with nothing to click to find it -
          // the menu item would look like it had done nothing. The failure path
          // in _runUpdateAction already calls showSpotlight for the same
          // reason; this is the success path's version of it.
          NSApp.activate()
          self.controller.checkForUpdates(nil)
          result(nil)
        case "setAutomaticChecks":
          guard self.started, let enabled = call.arguments as? Bool else {
            result(FlutterError(code: "invalid_state", message: "Cannot change update checks.", details: nil))
            return
          }
          self.controller.updater.automaticallyChecksForUpdates = enabled
          result(self.state)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "updater_error", message: error.localizedDescription, details: nil))
      }
    }
  }

  private var state: [String: Bool] {
    ["automaticChecks": controller.updater.automaticallyChecksForUpdates,
     "updateAvailable": updateAvailable]
  }

  // Scheduled checks never take focus away from the user's current work.
  // The tray menu changes to "Update available…" until the user opens it.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    updateAvailable = true
    channel.invokeMethod("stateChanged", arguments: self.state)
  }

  // Sparkle's alerts ("You're up to date", errors) are modal and are shown
  // from a block on the main dispatch queue, so the queue cannot drain until
  // the user dismisses them. Sentry's hang detector watches exactly that
  // queue, and reported every Check for Updates as a 2-second App Hang - the
  // time spent reading the dialog. Nothing is stuck; pause it while one is up.
  func standardUserDriverWillShowModalAlert() {
    SentrySDK.pauseAppHangTracking()
  }

  func standardUserDriverDidShowModalAlert() {
    SentrySDK.resumeAppHangTracking()
  }

  func standardUserDriverWillFinishUpdateSession() {
    updateAvailable = false
    channel.invokeMethod("stateChanged", arguments: state)
  }
}
