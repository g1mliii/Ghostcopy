# Current Work

## Active Task

**iOS bring-up** (2026-09-16 to 2026-09-17). iOS now builds, launches and
renders on the simulator for the first time. Committed as `0be7ed8`.

Branch note: `ios/bring-up` is branched off `macos/bring-up`, not `main`,
because PR #16 is still open and carries the auth/sandbox/sync fixes this
builds on. **The iOS PR must target `macos/bring-up`**, or its diff will
re-show the macOS commits. Retarget to `main` once #16 merges.

### Done

- [x] Builds: `flutter build ios --simulator --debug`
- [x] Launches and renders on an iPhone 17 simulator (iOS 27.0)
- [x] Welcome screen, tab switching, sign-in form all verified by hand
- [x] **UIScene life cycle migration.** This was not future-proofing - the iOS
      27 SDK makes it mandatory, and without it UIKit refuses to launch the app
      at all. That was the white screen. Flutter's automated migration only
      fires on a stock AppDelegate, so it was done by hand: scene manifest,
      `SceneDelegate` subclassing `FlutterSceneDelegate` for the privacy blur
      and deep links, `AppDelegate` on `FlutterImplicitEngineDelegate`, and
      `FlutterChannelHub` building the channels once from the engine messenger
- [x] Removed `NSExtension` from the app `Info.plist` - iOS was treating the
      whole app as an app extension
- [x] Pods deployment target floor for Xcode 27 (`ios/Podfile`)
- [x] SPM migration (22 packages SPM, 3 CocoaPods), `Package.resolved` committed
- [x] Supabase credentials + `user_id` moved to the App Group suite

Nothing in `lib/` changed. The Dart side was correct throughout.

### Next

- [ ] Sign in / sign out / account upgrade on iOS - never exercised
- [ ] `ios/Runner/GoogleService-Info.plist`. **Copying it in is not enough**:
      `Runner.xcodeproj` has no reference to it, which is why CI builds green
      without it and why `Firebase.initializeApp()` currently no-ops. It must
      be added to the Runner target's Copy Bundle Resources
- [ ] Wire `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` into the
      Runner target - referenced by nothing today, so no `aps-environment`
      and no App Group
- [ ] Set `DEVELOPMENT_TEAM = R9TKT8U45R` (what macOS uses)
- [ ] Decide: add a real widget extension target, or delete
      `ios/ClipboardWidget/`. There is no widget target - those four Swift
      files have never been in a build. If a target is added,
      `RefreshWidgetIntent` must read the App Group suite rather than
      `UserDefaults.standard`
- [ ] Register a test device, then `flutter run -d ios` on real hardware
- [ ] APNs end to end, the home screen widget, the share sheet

### Known, not chased

- `FLTGoogleSignInPlugin` logs its own UIScene deprecation warning. Plugin
  side, upstream
- `irondash_engine_context` and `super_native_extensions` have no SPM support.
  Upstream, and macOS depends on them too. Deliberately left alone
- `pod install` warns that CocoaPods did not set the base configuration
  because `Flutter/Release.xcconfig` does not include `Pods-Runner.profile.xcconfig`.
  Harmless so far; the likely symptom if it bites is the Profile configuration
  failing to link pods

## macOS: done 2026-09-16

Nobody had ever launched GhostCopy on a Mac before this session. It now builds,
runs, and has been exercised by hand. What was wrong and what was changed:

- [x] PRs #11, #12, #13 - already merged before the session began
- [x] Signing: `flutter build macos --release` works. The project already named
      the right team; it needed `-allowProvisioningUpdates` so Xcode could
      generate the missing development certificate and register the Mac
- [x] Removed the Accessibility prompt from `AppDelegate.swift`, and corrected
      the claim in CLAUDE.md that said the permission was required
- [x] Tray icon verified in a dark menu bar
- [x] Tray menu is now a real `NSMenu`, with Game Mode as a native checkmark.
      Windows keeps the custom Flutter window
- [x] Finder context menu: "Send with GhostCopy", via `NSServices`. The entry
      needs an empty `NSRequiredContext` - both Blip and TeamViewer ship one,
      and its absence is why an otherwise correct entry never appeared
- [x] Sandbox: added `files.user-selected.read-write`, which was blocking the
      upload button, save-to-computer, and drag-in
- [x] Auto-send resend loop: `stopClipboardMonitoring` cleared the dedupe hash,
      so every screen lock re-sent the clipboard on unlock
- [x] Clipboard monitor now checks `NSPasteboard.changeCount` before reading.
      It used to pull the whole payload every 5s - re-reading a copied file
      from disk in full - just to hash it
- [x] UI fixes: blank QR code, link-device overflow, chip hover flash, oversized
      toggles, unreadable staleness slider, duplicate delete toasts
- [x] Default devices now govern auto-send and both context menus, and the
      setting is visible on mobile as well as desktop
- [x] macOS default hotkey is Option+Space, Ctrl+Shift+S on Windows. A
      global hotkey takes its combination from every app, which rules out
      Cmd+Shift+S (Save As) and Cmd+Shift+V (paste-without-formatting).
      Option+Space does suppress the non-breaking space while the app runs -
      accepted deliberately, since it is the macOS launcher convention
      (Raycast, Alfred) and the character is one few users type on purpose

Measured on the release build: 48MB idle in the tray, ~125MB while the window
is visible, and no leak - the Dart heap held at 24MB across repeated open and
close cycles. Debug builds read ~270MB; do not use them to judge memory.

Still open:

- [ ] Sign in, sign out and account upgrade have not been tested on macOS
- [ ] `_showTrayMenu` calls `setAsFrameless()` and `setHasShadow(false)` and
      never restores either. Invisible on macOS; on Windows a frameless window
      has no non-client area, so this likely kills edge-resizing after the
      first tray-menu open. The fix needs `setWindowButtonVisibility(false)`
      alongside it, or the traffic lights come back - verify on Windows
- [ ] Launch-at-startup still unverified under the sandbox

## Later: clipboard export and import

After iOS. Not urgent, and deliberately not part of the account work it came
out of.

Signing into an existing account from a guest session leaves the guest's clips
behind, because they belong to the anonymous user_id and nothing can reach them
afterwards. Merging accounts was considered and rejected - it is a large amount
of conflict handling for a rare case, and it is not really the app's job. The
app now warns before that happens, and dormant guest accounts are expired after
90 days (`20260916220000_expire_dormant_anonymous_accounts.sql`).

Export/import answers it better, and answers more than it: backups, moving
between accounts, and leaving the product without losing anything.

- [ ] Export the signed-in user's clips to a portable file
- [ ] Import that file into another account
- [ ] Decide the format first - it is the part that has to outlive everything
      else. Needs content type, timestamps, device origin, and a decision on
      whether encrypted clips travel encrypted or are decrypted on export
- [ ] Files and images: either inline them or export a manifest plus a folder
- [ ] Does not need to be instant. A queued job that emails or exposes a
      signed download is cheaper than doing it synchronously, and sidesteps
      timeouts on large histories

## Later: AI assistant integration via MCP

After the remaining iOS reliability work. Let users ask an assistant to
"send this to my phone" or send a generated file to another device through
GhostCopy on macOS and Windows.

Prioritize a local MCP integration for Claude Desktop and ChatGPT/Codex.
Reuse GhostCopy's sending services, account and encryption. A CLI can follow
later using the same implementation for scripts and coding agents.

- [ ] Expose tools to list devices, send text or links, and send files
- [ ] Target a specific device by ID, resolving names such as "my phone"
- [ ] Make the connection opt-in; keep clipboard-history access a separate
      permission if added later
- [ ] Report queued/sent accurately; only report received with a delivery
      acknowledgement
- [ ] Provide straightforward setup and verify both desktop platforms
- [ ] Trial the "send this to my phone" workflow before expanding scope
- [ ] Consider a CLI after the MCP integration is useful and reliable

## Parallel track: Google Play

Play Console account purchased 2026-09-15. Full path:
[`left_TO_DO/PLAY_STORE_SETUP.md`](../left_TO_DO/PLAY_STORE_SETUP.md)

Front-load this. A new personal account must run a closed test with 20 testers
for **14 continuous days** before it can apply for production, so the clock
should start as early as a build allows and run while the macOS work happens.

- [ ] Generate the upload keystore, add `android/key.properties` (Gradle is
      already wired for it)
- [ ] Bump `version:` off the default `1.0.0+1` and pick a scheme
- [ ] `flutter build appbundle --release`, verify it is not debug-signed
- [ ] Create the app in Console; privacy policy, data safety, content rating
- [ ] Upload to closed testing and recruit 20 testers — **starts the 14 days**

---

## Completed: Phase 1.2 - MobileMainViewModel Extraction

**Completion Date**: 2026-02-12

**Acceptance Criteria**:
- [x] Extract all business logic from MobileMainScreen to MobileMainViewModel
- [x] Use ChangeNotifier for state management
- [x] ViewModel created locally in widget (not locator - screen stays alive)
- [x] Zero memory leaks (all timers/subscriptions/caches disposed)
- [x] Zero compilation errors
- [x] Zero lint warnings
- [x] Achieve ~29% line reduction in MobileMainScreen
- [x] Audit for memory leaks, performance, and security

**Results**:
- **Created**: `lib/ui/viewmodels/mobile_main_viewmodel.dart` (1,180 lines)
  - All business state: isSending, devices, historyItems, caches, etc.
  - All business logic: handleSend(), loadDevices(), loadHistory(), autoCopy, etc.
  - Lifecycle hooks: onAppPaused(), onAppResumed(), onMemoryPressure()
  - Proper disposal: timers, subscriptions, caches all cleaned up

- **Refactored**: `lib/ui/screens/mobile_main_screen.dart` (2,010 lines, down from 3,147)
  - 36.1% reduction (1,137 lines removed)
  - Retained: text controllers, animations, method channels, lifecycle observer, dialogs
  - Added: ViewModel listener pattern with setState integration
  - UI callbacks via closures (onSuccess, onError) for toasts/snackbars

**Audit Results (Memory/Performance/Security)**:
- [x] Memory: All timers cancelled, subscriptions cancelled, caches cleared in dispose()
- [x] Memory: _isDisposed flag prevents notifyListeners() after disposal
- [x] Performance: Services remain singletons (injected from locator)
- [x] Performance: WidgetService() uses factory constructor returning singleton
- [x] Security: Fixed _autoCopyToClipboard to check item.isEncrypted before decrypting
- [x] Security: Clipboard auto-clear still works on app background
- [x] Security: Sensitive data detection still checked before send

**Verification**:
- [x] Static analysis: `flutter analyze` -> **0 errors, 0 warnings**
- [x] Memory management: All resources properly disposed
- [x] Pattern: Clean MVVM separation achieved

---

## Completed: Phase 1.1 - SpotlightViewModel Extraction

**Completion Date**: 2026-02-08

**Results**:
- **Created**: `lib/ui/viewmodels/spotlight_viewmodel.dart` (585 lines)
- **Refactored**: `lib/ui/screens/spotlight_screen.dart` (2,565 lines, down from 2,962)
  - 13.4% reduction (397 lines removed)

---

## Next Steps

Ready to proceed with:
- **Phase 2.1**: Shared StaggeredHistoryItem widget extraction
- **Phase 2.2-2.4**: Remaining widget extractions (platform chips, etc.)
- **Phase 3**: Tests and polish
- **Manual Testing**: Verify send/receive flows work correctly on mobile

---

## Plan Template

When starting a new non-trivial task, copy this template:

```
### [Task Name]

**Acceptance Criteria**:
- [ ] [What must be true when done]

**Steps**:
- [ ] Restate goal + acceptance criteria
- [ ] Locate existing implementation / patterns
- [ ] Design: minimal approach + key decisions
- [ ] Implement smallest safe slice
- [ ] Add/adjust tests
- [ ] Run verification (lint/tests/build/manual repro)
- [ ] Summarize changes + verification story
- [ ] Record lessons (if any)

**Verification**:
- [ ] Tests pass
- [ ] Lint/typecheck clean
- [ ] Build successful
- [ ] Manual verification: [describe]

**Results**:
<!-- Fill in after completion -->
- Changed: [files/components]
- Verified by: [tests/commands run]
```
