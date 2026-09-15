# macOS: first session on the Mac

**Rewritten 2026-09-15.** The previous version claimed macOS was "nearly
complete ✅" and listed most features as done. That was written from reading the
source, not from running it. Nobody has ever launched GhostCopy on a Mac.

What is actually known, as of 2026-09-15:

| | Status | Evidence |
|---|---|---|
| Windows | Builds, runs, used daily | Local + CI |
| Android | Builds, runs | Local + CI |
| iOS | **Compiles.** Never run. | CI run 34999420416 |
| macOS | **Does not build.** Never run. | CI run 34999420416 |

So the doc below is a task list, not a verification checklist. Nothing here is
confirmed working until you confirm it.

---

## 0. Before anything else

Merge the open PRs first, or you will clone a repo that cannot build:

- **#12** commits `pubspec.lock`. Without it a fresh clone resolves
  `material_ui 1.3.0`, which needs a newer SDK than the pinned Flutter 3.44.8,
  and every native target fails with `Undefined name 'awaitNotRequired'`.
- **#11** is the Supabase RLS migration.
- **#13** gates deploys on CI being green.

Then:

```bash
git clone https://github.com/g1mliii/Ghostcopy.git
cd Ghostcopy
flutter pub get          # honours the committed lockfile - do not run pub upgrade
```

You also need a `.env` (see the root `README.md`); it is gitignored, so copy it
across from the Windows machine.

---

## 1. Fix the build — this is the actual first task

`flutter build macos --release` currently fails in CI with:

```
macos/Runner.xcodeproj: error: No profiles for 'com.ghostcopy.ghostcopy' were found:
Xcode couldn't find any Mac App Development provisioning profiles matching
'com.ghostcopy.ghostcopy'. Automatic signing is disabled and unable to generate a profile.
```

This is signing, not code. On your own Mac with an Apple ID it should resolve
by selecting a team:

1. `open macos/Runner.xcworkspace`
2. Select the **Runner** project → **Runner** target → **Signing & Capabilities**
3. Tick **Automatically manage signing**, pick your team (a free personal Apple
   ID works for local development)

`flutter run -d macos` for development does not need this; only `--release`
does. Try `flutter run -d macos` first — it may just work.

**CI will still fail after you fix it locally**, because the runner has no
signing identity and there is no `--no-codesign` flag for
`flutter build macos` the way there is for iOS. Leave it failing, or make the
CI job build unsigned via `CODE_SIGNING_ALLOWED=NO` in the Release xcconfig.
The macOS job is `continue-on-error: true`, so it is not blocking anything.

---

## 2. The Accessibility prompt is wrong — remove it

`macos/Runner/AppDelegate.swift` calls `AXIsProcessTrustedWithOptions` with
`kAXTrustedCheckOptionPrompt: true` on every launch, commented "needed for
global hotkeys".

**It is not needed, and it cannot work.** Two independent reasons:

1. `hotkey_manager` → `hotkey_manager_macos` → the `HotKey` pod (0.2.1, from
   `macos/Podfile.lock`), which wraps Carbon's `RegisterEventHotKey`. That API
   has never required Accessibility permission — that requirement applies to
   `CGEventTap` / `NSEvent.addGlobalMonitorForEvents`, which this app does not
   use.
2. `macos/Runner/Release.entitlements` sets
   `com.apple.security.app-sandbox = true`. A sandboxed app cannot hold
   Accessibility trust in any useful way.

Net effect: every user gets a scary system permission dialog on first launch,
for a permission the app does not use and would not be able to use.

**Task:** delete `checkAccessibilityPermissions()` and its call in
`applicationDidFinishLaunching`. Verify the hotkey still works afterwards — it
should, unchanged.

*(This corrects advice given earlier in the 2026-09-15 session, which said to
grant Accessibility on first launch. That was wrong for this stack.)*

---

## 3. Check the tray icon in a dark menu bar

The desktop icons were regenerated on 2026-09-15 (`tool/generate_desktop_icons.py`).
The macOS tray asset is `assets/icons/tray_icon_macos.png`: a 44px black-on-
transparent **template** image, which AppKit tints to match the menu bar.

That tinting only happens because `lib/services/impl/tray_service.dart` passes
`isTemplate: Platform.isMacOS` to `trayManager.setIcon`. Before that change the
flag was never passed, which would have rendered a literally-black icon —
invisible in a dark menu bar.

**This is the one change from that session that could not be verified on real
hardware.** Check:

- [ ] Icon is visible in a **light** menu bar (should render dark)
- [ ] Icon is visible in a **dark** menu bar (should render light) ← the one that was broken
- [ ] Icon inverts correctly when the menu bar item is clicked/highlighted
- [ ] Icon is crisp on a Retina display, not blurry (it is drawn at 44px = 22pt @2x)

If it is wrong, regenerate with `python tool/generate_desktop_icons.py` rather
than editing the PNG; see `assets/icons/README.md`.

---

## 4. Sandbox vs. launch-at-startup

`lib/services/impl/auto_start_service.dart` exists and there is a settings
toggle, but it has never run on macOS. Sandboxed apps cannot use the older
login-item APIs; they need `SMAppService` (macOS 13+) or a bundled login-item
helper.

**Task:** verify the toggle actually survives a logout/login. Expect this to be
broken. If it is, that is a real piece of work, not a config tweak.

---

## 5. Then the normal functional pass

None of this has been exercised on macOS. Work through it in order — each
depends on the one before.

- [ ] `flutter run -d macos` launches without crashing
- [ ] Window starts hidden; app does not appear in the Dock as a normal window
- [ ] Tray icon appears in the menu bar
- [ ] Global hotkey shows the Spotlight window, centred and focused
- [ ] `Esc` hides it; `Cmd+W` does **not** quit the app
- [ ] Only `Cmd+Q` or the tray Quit actually exits
- [ ] Right-click tray → menu renders (it is a custom Flutter window, not an
      `NSMenu`, so this is a real risk on macOS)
- [ ] Sign in works (Supabase; the app is sandboxed with
      `com.apple.security.network.client`, which should be sufficient)
- [ ] Send a clip from macOS → arrives on Windows
- [ ] Send a clip from Windows → auto-copies on macOS
- [ ] Sleep the Mac, wake it, confirm sync recovers
      (`macos/Runner/PowerMonitor.swift` bridges `willSleep`/`didWake`)

---

## Known macOS-specific risks, ranked

1. **The custom tray menu.** `lib/ui/widgets/tray_menu_window.dart` is a
   borderless Flutter window positioned near the tray icon, not a native
   `NSMenu`. Window positioning, focus and click-outside-to-dismiss are the
   things most likely to behave differently from Windows.
2. **Sandbox restrictions.** Auto-start (above) is the known one. Watch for
   anything touching paths outside the container —
   `lib/services/impl/temp_file_service.dart` is worth a look.
3. **Hotkey conflicts.** macOS reserves more system-wide combinations than
   Windows. The hotkey is user-configurable
   (`lib/ui/widgets/hotkey_capture_field.dart`), so this is a support question,
   not a bug.
4. **Window level.** The Spotlight window needs to float above other apps.
   Check it appears over a fullscreen app, which is a separate window-level
   concept on macOS.

---

## What is genuinely already in place

Verified by reading the source, not by running it:

- `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`,
  so closing the window keeps the app alive in the tray
- `PowerMonitor.swift` observes `willSleep` / `didWake` /
  `screensDidLock` / `screensDidUnlock` and bridges them over a method channel
- `Release.entitlements` has app-sandbox + network-client + a keychain access
  group
- The Dock/app icon art is current (updated 2026-09-15 along with everything else)
- All the Dart services are platform-shared with Windows, which is the tested
  platform — the business logic is unlikely to be where macOS breaks

---

## macOS vs iOS: do macOS first

iOS already compiles; macOS does not. macOS is also where the unshared work is
— tray, hotkey, window management — and it needs no device provisioning or
signing ceremony to iterate on. iOS additionally needs a real device to test
anything that matters (APNs, clipboard, the home screen widget), so it is a
bigger setup step for a platform that is currently in better shape.
