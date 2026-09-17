# Current Work

## Active Task

**iOS bring-up** (started 2026-09-16, in progress). macOS is done bar sign-in
testing.

Branch note: `ios/bring-up` is branched off `macos/bring-up`, not `main`,
because PR #16 is still open and carries the auth/sandbox/sync fixes this
builds on. **The iOS PR must target `macos/bring-up`**, or its diff will
re-show all four macOS commits. Retarget to `main` once #16 merges.

### Where it stands

iOS builds and launches on the simulator for the first time. It renders a
blank white screen - that is the next thing to chase.

- [x] `flutter build ios --simulator --debug` - **passes**
- [x] Installs and launches on the iPhone 17 simulator (iOS 27.0)
- [ ] **Blank white screen.** Not a startup crash: the Dart side comes up
      cleanly - `Supabase init completed`, `DeviceService`, `SettingsService`
      all initialize, `TempFileService` runs its cleanup. So this is a
      render/routing problem inside the Flutter app, not native. Start by
      checking what the mobile route resolves to when `IFcmService` and
      `IWidgetService` were never registered (Firebase is skipped without
      `GoogleService-Info.plist`, which is expected on the simulator)
- [ ] Functional pass: send/receive, history, settings, auth

### Fixed to get this far (uncommitted, in the working tree)

- **Pods deployment target.** Xcode 27 rejects `IPHONEOS_DEPLOYMENT_TARGET =
  13.0` (it supports 15.0+). The 13.0 came from `PBXAggregateTarget "Flutter"`
  - Flutter's own generated podspec pins `ios.deployment_target = '13.0'` and
  podhelper only strips values strictly *below* 13. `ios/Podfile` now forces
  16.0 on every pod target's configurations, mirroring what `macos/Podfile`
  already did. CI never caught this because CI runs an older Xcode
- **`NSExtension` removed from the app `Info.plist`.** It made iOS treat the
  whole app as an app extension - `Dynamic content size update is not
  supported in app extension` in the log. A live runtime bug, not just an App
  Store risk, and invisible to `flutter build --no-codesign`. (Removing it did
  *not* fix the blank screen - that is a separate problem)
- **SPM migration.** The first build migrated iOS from pure CocoaPods to Swift
  Package Manager: 22 packages via SPM, 3 still via CocoaPods (Flutter,
  `irondash_engine_context`, `super_native_extensions`). This was not a choice
  - SPM is `enabledByDefault: true` on stable, so any machine and CI does the
  same. macOS was already migrated and committed in PR #16; iOS was the last
  platform on pure CocoaPods
- `ios/Flutter/AppFrameworkInfo.plist` lost its stale `MinimumOSVersion 13.0`
  (Flutter removed it automatically)

Decision: the two non-SPM plugins are **not ours to fix**. Neither ships a
`Package.swift`; both are upstream (Matej Knopp) and arrive transitively via
`super_clipboard` / `super_drag_and_drop`. Flutter's "will become an error"
is a future warning, not a deadline. Leave it; macOS depends on them too.

### Next: UIScene lifecycle migration

Agreed to do this from the ground up while iOS is greenfield. Flutter's
automated migration (`flutter_tools/lib/src/migrations/uiscene_migration.dart`)
**only fires if AppDelegate matches a stock template byte-for-byte**, and
GhostCopy's is 344 lines of custom code, so it silently skips and prints the
warning. Must be done by hand.

- [ ] `Info.plist`: add `UIApplicationSceneManifest` naming `FlutterSceneDelegate`
      (the engine ships it - `FlutterSceneDelegate.h`) with `UISceneStoryboardFile: Main`
- [ ] `AppDelegate`: conform to `FlutterImplicitEngineDelegate`, move
      `GeneratedPluginRegistrant.register` into
      `didInitializeImplicitFlutterEngine(_:)`
- [ ] Replace all five `window?.rootViewController as? FlutterViewController`
      lookups with `engineBridge.applicationRegistrar.messenger()`, and build
      the three method channels (share, widget, notifications) **once** as
      properties instead of reconstructing them per call. Worth doing on its
      own merits: today those methods `guard let ... else { return }` and
      silently drop the message if the root VC is not ready - a real failure
      mode for a notification arriving during launch
- [ ] Subclass `FlutterSceneDelegate` and move the privacy blur to
      `sceneWillResignActive` / `sceneDidBecomeActive`. Note: the blur
      currently fires during launch (`applicationWillResignActive` runs right
      after `applicationDidBecomeActive`) - check whether that is spurious
- [ ] Separately, `FLTGoogleSignInPlugin` logs its own UIScene deprecation
      warning. Plugin-side, not ours

### Still to do: the remaining project-config defects

Deliberately kept out of the bring-up commit as a separate reviewable change.

- [ ] Wire `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` into the
      Runner target - it is referenced by nothing today, so the app has no
      `aps-environment` and no App Group
- [ ] Set `DEVELOPMENT_TEAM = R9TKT8U45R` (what macOS uses)
- [ ] Supabase credentials and `user_id` to the App Group suite on both sides:
      `AppDelegate.storeSupabaseCredentials` writes `UserDefaults.standard`,
      `RefreshWidgetIntent` reads `UserDefaults.standard`, and nothing writes
      `user_id` at all
- [ ] Decide: add a real widget extension target, or delete
      `ios/ClipboardWidget/`. There is no widget target in the project -
      those four Swift files have never been in a build.
      `left_TO_DO/IOS_WIDGET_SETUP.md` documents the manual Xcode steps that
      were never carried out

### Blocked on hardware / config

- [ ] `ios/Runner/GoogleService-Info.plist` (gitignored; from the Firebase
      console or the Windows machine)
- [ ] APNs auth key uploaded to Firebase - the entitlement alone is not enough
- [ ] Register the test device, then `flutter run -d ios` on it
- [ ] APNs end to end, the widget, the share sheet

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
