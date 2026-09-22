# Current Work

## Active Task

**macOS release** (2026-09-19 onward), on `codex/macos-installer` (PR #18).
Installer and Sparkle updates both verified end to end against a local feed;
the first publish is the remaining step. See
[`docs/macos-releases.md`](../docs/macos-releases.md) for the runbook and
`installer/macos/VERIFICATION.md` for what was actually exercised.

## Done: iOS bring-up

2026-09-16 to 2026-09-17, merged as PR #17. iOS runs on real hardware. Two
post-mortems from it - the silent push outage and why the notification Copy
action is gone - are in [`tasks/lessons.md`](lessons.md).

### Done

- [x] Builds, signs and runs on an iPhone 15 Pro, and on the simulator
- [x] Google sign-in, sync, history, encryption all working on device
- [x] **UIScene migration.** Mandatory on the iOS 27 SDK - without it UIKit
      refuses to launch the app at all. That was the white screen
- [x] `NSExtension` removed from the app Info.plist - iOS was treating the whole
      app as an app extension
- [x] Camera crash fixed (`NSCameraUsageDescription`) - would have killed
      onboarding on first launch, since the welcome screen opens on the QR tab
- [x] QR scanner never initialised on a cold launch (shared with Android)
- [x] Entitlements, App Group and `DEVELOPMENT_TEAM` wired into the target
- [x] `GoogleService-Info.plist` added to Copy Bundle Resources - copying the
      file in was never enough, nothing referenced it
- [x] Squircles on Apple platforms (`Adaptive.surfaceShape`), iOS spinner on the
      four mobile paths that still drew Material's
- [x] Notification flow simplified: tap opens the app and copies, or opens the
      share sheet for files. No long-press actions
- [x] Cold-launch notification taps no longer lost (native parks, Dart collects)
- [x] Passphrase storage hardened - see below

### Tested on the phone - 2026-09-22

- [x] Text clip: notification tap opens the app and the clipboard holds the clip
- [x] File or image: tap opens the app and the share sheet
- [x] Cold launch after swiping the app away, via the deferred-tap handoff

### Later: request the iOS device-name entitlement

`com.apple.developer.device-information.user-assigned-device-name`, requested
from Apple rather than enabled in the portal - developer.apple.com, Contact ->
Request. Since iOS 16 `UIDevice.name` returns the model, so a phone reports
"iPhone" instead of "Subai's iPhone"; the entitlement restores the real name.

The device-row collision this once blocked is solved, and no longer waits on
Apple. `initializeDeviceName()` appends the first eight characters of
`identifierForVendor` to the label, so two iPhones on one account produce
different `device_name` values and no longer collide on the
UNIQUE (user_id, device_type, device_name) index - which was the failure where
they shared one row and one FCM token and whichever launched last won. What is
left is cosmetic: without the entitlement the readable half is the model, so a
phone reads "iPhone 15 Pro - a1b2c3d4" rather than "Subai's iPhone".

The Simulator is not subject to the entitlement gate and returns its full
assigned name, which is why this looks fine in testing.

Nothing is blocked on it now, so it is worth requesting in the background and
forgetting about. Apple are selective and may decline.

The justification that fits: users manage several devices, the settings screen
lists them, and clips are labelled by which device sent them - so identifying a
device by the name its owner gave it is the point rather than a convenience.

No code change if granted, as the code stands: `initializeDeviceName()` already
reads `ios.name` first and only falls back to the model identifier when it comes
back empty. If the interim swap above is taken, granting it means reversing that
preference again.

- [ ] Submit the request
- [ ] If granted, add the key to `ios/Runner/Runner.entitlements`

### Accessibility pass, both platforms - done 2026-09-18

Audited at the top content size on a device, not guessed at. Screenshots were
the only reliable oracle: a red-pixel counter and a log grep for the overflow
banner both reported clean while the screenshots plainly showed "BOTTOM
OVERFLOWED BY 16 PIXELS".

- [x] **Dynamic Type / textScaler.** Welcome screen, settings, spotlight and
      the device chips all reflow now. The device-selector chips needed the
      `SizedBox` around the horizontal `ListView` loosened, not just the chip -
      fixing the chip alone left the labels as glyph fragments
- [x] **Touch target sizes** - one deliberate exception: Settings' delete
      button is 40dp, sized that way to fix a dead-space bug. Revisit if it
      ever reads as hard to hit
- [x] **Screen reader labels** on the icon-only controls
- [x] **Contrast ratios.** `textMuted` on `surface` measures 6.4:1 and was
      never the problem

- [ ] **`primary` as a foreground is 4.44:1 on `surface`**, just under AA. Not
      part of the pass above because it is a palette decision, not a fix: it is
      used as a foreground in ~104 places, so either the token moves or those
      call sites move to `accentText` (8.98:1) one at a time. The email
      templates already took the second route

### Open

- [x] **Cmd+Q on macOS - decided against 2026-09-18, will not do.** The
      original entry argued it should intercept Cmd+Q and hide instead, the way
      menu-bar apps often do. Rejected on the owner's call: Cmd+Q means quit,
      and an app that keeps syncing the clipboard after the user quit it is the
      worse surprise. Leaving it alone.


- [x] **Per-device names - done.** Every iOS device used to register as "iOS
      Device" against
      a UNIQUE (user_id, device_type, device_name) index, so a simulator and a
      phone share one row and one FCM token - whichever launched last wins, and
      the other silently stops receiving push. Same for two Androids. Needs
      `device_info_plus` as a direct dependency, async resolution (the getter is
      synchronous and read on every send), and a decision about existing rows.
      Note iOS gives only the model name without an Apple entitlement
- [x] **Keychain accessibility - done 2026-09-18.** The passphrase and its
      verification hash now live under `first_unlock`
      (`kSecAttrAccessibleAfterFirstUnlock`) instead of the default
      `kSecAttrAccessibleWhenUnlocked`, so the push-woken isolate can decrypt on
      a locked phone. Done as the migration it always was, in
      `lib/services/impl/keychain_accessibility.dart`: read under the old
      options, delete, write under the new, read back, and restore under the old
      options if any of that fails. The delete-before-write window is
      unavoidable - SecItemAdd matches on service and account alone, so the new
      item cannot be added while the old one is there - which is why the restore
      exists rather than a rethrow. Runs on iOS only, on every launch, and is a
      no-op once nothing is left under the old options.

      Takes effect after one *unlocked* launch. On a locked phone the old item
      cannot be read, so the migration finds nothing and correctly does nothing;
      that push falls back to opening the app, as it does today. Not applied to
      macOS - same Keychain mechanics, but nothing wakes on a locked Mac, so it
      would be a second migration bought for nothing.

      Still to confirm on the device, and it cannot be checked on a fresh
      install: it needs one that already holds a passphrase written by an older
      build. Note simulator Keychain items survive app uninstalls, which is what
      disguised this last time.
- [x] Home screen widget - REMOVED on both platforms. An iOS widget extension
      cannot write the general pasteboard on a real device, so a tap could only
      open the app; not worth maintaining for that, and the Android half alone
      did not justify it either.
- [x] iOS share sheet **into** the app - done. ios/ShareExtension now exists
      and the plugin owns the share sheet on both platforms; the hand-rolled
      Android path that ran alongside it is gone. Shares auto-send to the
      "Send to devices" targets
- [ ] `flutter logs` returns nothing from a profile build on device. The
      background isolate is only observable by writing files to the app
      container and reading them with `devicectl device info files`
- [ ] Publishable key migration is done in the app; **do not disable legacy API
      keys** until every released build carries it

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

## Before submission

- [ ] One more look at the app mark with fresh eyes. The Discord-distance work
      is done and verified in `colors.dart` - the mark was replaced outright
      with a clipboard/speech-bubble that carries its own silhouette, and
      `primaryHover` moved off Discord's dark blurple - but "far enough" is a
      judgement call rather than a measurement, and it is cheaper to revisit
      now than after App Review.

## Cross-platform verification: next manual pass

- [ ] **System notifications.** Verify a received clip produces a native
      notification while Game Mode is off on macOS and Windows; verify Game
      Mode suppresses it and that the notification tap opens/copies the clip.
      On macOS this means Notification Center/banner permissions and the menu
      bar app's `NSUserNotification`/UserNotifications delivery. On Windows
      this means the Windows toast notification (and its Action Center entry),
      including a fresh-install permission check.
- [ ] **Encryption after reinstall/account switch.** Install over an existing
      Keychain entry, sign into the same account, and confirm encrypted history
      appears without toggling encryption or signing out again.
- [ ] **Background resource check.** Measure a release build in the tray after
      15 minutes and while the window is closed: resident memory, CPU, and
      thread count. The previous baseline was about 48 MB in tray, 125 MB with
      the window open, and 24 MB Dart heap; the reported 116 MB/12 threads/
      0.4% CPU should be compared against that baseline before further tuning.
      Capture one macOS Activity Monitor sample and one Windows Task Manager
      sample before changing the lifecycle or realtime services.
- [ ] **Obsidian integration.** Run the configured export path with text,
      Markdown, and a filename containing spaces/Unicode; confirm the file is
      written to the selected vault and failures are reported.
- [ ] **Webhook integration.** Point the webhook at a request inspector,
      send text, image, and file clips, and verify payload shape, signing/auth,
      retry behavior, and that a failed endpoint does not block clipboard sync.

## Monitoring, error tracking and cost guards

From a monitoring plan reviewed 2026-09-22. Most of its cost-control advice is
already implemented here, and more strictly than it suggested - recorded below
so nobody builds it twice.

### Already in place

| Recommendation | What the repo does |
|---|---|
| Tag origin device so B does not echo back to A | `isFromDifferentDevice = deviceName != currentDeviceName` (`clipboard_sync_service.dart:163`, `:345`) |
| Debounce client clipboard events | 5-second poll (`clipboard_sync_service.dart:474`) |
| Per-user rate limit, suggested 30/min | **10/min**, Postgres trigger `check_clipboard_rate_limit` (`schema.sql:152`) |
| Payload cap, suggested 15-20 MB | 100 KB text (`maxContentLength`), 10 MB files (`ClipboardLimits.maxFileBytes`) |
| Bounded retention and storage cleanup | `20260915000000_bound_cleanup_and_rate_limits.sql`, R2 deletion queue |

The infinite-sync-loop footgun that plan leads with is therefore closed on the
application side. The remaining exposure is billing, which is not in the repo.

### Now - dashboard only, no code, no dependency on any platform

- [ ] Google Cloud (Firebase) Billing -> Budgets & Alerts: thresholds at 50%,
      80%, 100% with email alerts
- [ ] Supabase Project Settings -> Billing: spend cap or usage notifications on
      Database Egress, Database Size, and Edge Function invocations
- [ ] Cloudflare Account -> Notifications: R2 storage capacity and request
      thresholds, plus 5xx rate spikes

These are the only items where waiting has an asymmetric cost: a runaway bill
happens in hours and cannot be capped retroactively. About fifteen minutes.

### With the first public build, not after it

- [ ] **Sentry in the client.** Ordering matters: it has to be compiled into
      the build that ships. Ship without it and the first real crashes are
      invisible, and seeing them costs a whole new signed, notarized release.
      Scrub clipboard content from every event before sending

### After Windows, iOS and macOS are out

Diagnostics for a system with real traffic. With no users they are scaffolding
to maintain, not signal.

- [ ] Sentry in the Supabase Edge Functions (`@sentry/deno`) - deploys are
      instant, so this has no ordering constraint
- [ ] A `sync_id` UUID generated per clipboard event, passed through the edge
      function, R2 upload metadata and FCM payload, and attached to Sentry
      tags. Turns "the image did not sync" into one query
- [ ] A `/health` edge function doing `SELECT 1`, pinged every 60s by an
      external monitor
- [ ] Sync latency: log `receive_timestamp - create_timestamp` and watch P95.
      A creeping P95 is the first sign of FCM backlog or a missing index

### Decided against for now

- Log drains to Axiom or Better Stack. Supabase's built-in log retention plus
  Sentry covers this until retention expires before problems are noticed, or
  alerting on raw log patterns is needed. The source plan reached the same
  conclusion.

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

## Release: signing, distribution and updates

Written 2026-09-19. The facts below were checked against the repo, not
remembered - where something is unverified it says so.

### The two decisions, already made

**macOS ships with Developer ID, not the Mac App Store.** The sandbox is
mandatory only for the store, so it is gone (`macos/Runner/*.entitlements`).
That removes two problems at once: Sparkle needs an XPC service bundle and
extra entitlements to update a sandboxed app, and launch-at-startup was never
verified working under it.

The keychain survives that change. flutter_secure_storage sets
`kSecUseDataProtectionKeychain` on macOS - `MacOsOptions` defaults it to true
and nothing in `lib/` overrides it - so the keychain it uses does not depend on
the sandbox, and `keychain-access-groups` is unchanged. Still worth confirming
on a Mac that already holds a passphrase rather than a clean one; that is the
shape of mistake tasks/lessons.md records for 2026-09-17.

**Windows ships through the Microsoft Store.** Registration is now free for
both Individual and Company accounts, via https://storedeveloper.microsoft.com
- that entry point specifically, since Partner Center and Visual Studio still
route to the paid legacy flow. The Store signs the package and handles updates,
which avoids a code-signing certificate and removes the WinSparkle half of the
updater work entirely.

Unsigned direct download was the alternative and is worse than it sounds: not
just an "unknown publisher" UAC prompt but SmartScreen, whose reputation
accrues per certificate. Unsigned it accrues per file hash instead, so it
resets on every release and every auto-update re-triggers the warning.

Account type needs deciding before signing up - Individual is defined as
distribution NOT in relation to a business or profession, so a released product
points at Company, which wants a DUNS number or business documents and a work
email on the organisation's domain. Note the domain there: the contact address
is on anchored.site while the product is ghostcopy.app. **Individual cannot be
converted to Company later** - it needs a new account.

### Order

Roughly by how long each takes to come back, not by how much work it is.

- [ ] **Play closed test first.** 20 testers for 14 CONTINUOUS days before
      production can even be applied for, and it runs unattended. See the
      Google Play section below; start it the day a build exists.
- [ ] **Pick a version scheme.** `pubspec.yaml` is still `1.0.0+1`. TestFlight
      and Play both reject a duplicate build number, so decide before the first
      upload rather than during it.
- [ ] **iOS TestFlight.** Signing is `Apple Development` today, which is a
      development identity - TestFlight needs Apple Distribution.
- [ ] **macOS Developer ID.** Same wrong identity in
      `macos/Runner.xcodeproj` (`CODE_SIGN_IDENTITY[sdk=macosx*] = "Apple
      Development"`); needs a Developer ID Application cert. Hardened Runtime
      is now enabled on the Release config, which notarization requires and
      which was absent.
- [ ] **Notarize in CI.** `xcrun notarytool submit --wait` then `xcrun stapler
      staple`, with an App Store Connect API key in secrets. CI already builds
      macOS on `macos-latest` and currently stops at `flutter build macos
      --release`.
- [ ] **Windows Store submission.** CI already builds Windows on
      `windows-latest`, so no Windows machine is needed. Packaging moves from
      the Inno Setup script to MSIX for the Store.
- [ ] **Sparkle + appcast for macOS only.** The `auto_updater` package wraps
      Sparkle and WinSparkle behind one Dart API; only the macOS half is needed
      if Windows goes through the Store. There is no updater dependency in
      `pubspec.yaml` today.
- [ ] **Land the updater before any wide release.** The Supabase publishable
      key is compiled in, and legacy API keys cannot be disabled until every
      released build carries it. Once builds are out, an update is the only way
      to change a compiled-in constant.

### macOS installer and updater - verified 2026-09-22

Both paths exercised end to end against a local feed; nothing published yet.
Details in `installer/macos/VERIFICATION.md`, runbook in
`docs/macos-releases.md`.

- [x] Notarized drag-to-install DMG, installed and launch-tested
- [x] Sparkle build 2 -> build 3 upgrade via the CLI and via the update dialog
- [x] Install quits and relaunches the app by itself
- [x] Release notes embedded in the signed appcast (they were missing; a
      published update would have shown a blank dialog)
- [x] `CFBundleDisplayName`, copyright and `pubspec` version corrected for
      release, and `verify-app.py` now refuses an export missing the first
- [ ] Publish the first release, then confirm **Check for Updates…** against
      the live feed. It errors today, correctly: the `macos-updates` feed 404s
      because nothing has been published.
- [ ] Decide whether the gentle reminder is too quiet. A scheduled check shows
      only a dot next to the menu bar icon and relabels the tray item; someone
      who never opens that menu never updates.
- [ ] A stale `~/Library/Containers/com.ghostcopy.ghostcopy` from the sandboxed
      era still exists on dev machines and makes plain `defaults` target the
      container rather than the prefs the unsandboxed app actually uses. Only
      affects machines that ran a sandboxed build; delete it there.

### Distribution

- [ ] **Binaries on GitHub Releases, not the site.** Cloudflare Pages caps
      individual file size (25 MiB, worth confirming) and a Flutter desktop
      build is far larger - the debug macOS app measures 192 MB. The repo is
      public, so Releases bandwidth and Actions minutes are free, the URLs are
      permanent and versioned, and a Sparkle appcast points at release assets
      as a matter of course.
- [ ] **`website/download.html` is still a waitlist page** with no download
      links at all. The desktop links and the store badges are net-new.
- [ ] **Detect the OS to emphasise a store, but never auto-redirect.** Show
      both badges. User-agent detection is wrong in exactly the cases that
      matter - iPadOS reports as macOS in desktop mode, in-app browsers lie -
      and a wrong redirect is a dead end with no way back.

### Unverified, worth knowing before the first archive

- [x] `macos/Runner.xcodeproj` carried 14 references to a `ShareExtension`
      target with no `macos/ShareExtension` directory. Removed in `469d1d8`,
      and answered either way since: Release archive, Developer ID export and
      notarization have all succeeded repeatedly (builds 1-3).
- [ ] Windows and Linux `.ico` rendering has never been looked at on those
      platforms. The ICO writer was rewritten and `assets/icons/tray_icon.ico`
      - the file `tray_service.dart` actually loads on Windows - had not been
      regenerated since the rebrand.

---

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
- [x] Performance: services use factory constructors returning singletons
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
