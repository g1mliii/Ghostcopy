# Current Work

## Active Task

**macOS wrap-up, then Windows.** macOS 1.0.0 (5) is published: notarized DMG
on GitHub Releases, and the `macos-updates` appcast is live and serving
build 5. See [`docs/macos-releases.md`](../docs/macos-releases.md) for the
runbook, `installer/macos/VERIFICATION.md` for what was exercised, and
[`docs/macos-performance.md`](../docs/macos-performance.md) for the measured
resource baseline. Finished work is in git history and
[`tasks/lessons.md`](lessons.md), not here.

## macOS: what's left

- [x] **Launch at startup - fixed 2026-09-22 and confirmed.** The
      `launch_at_startup` package ships no macOS code;
      `macos/Runner/LaunchAtStartup.swift` answers its channel with
      `SMAppService.mainApp`. Checked on an installed build - a copy run from
      `build/` registers that path instead
- [x] **Gentle update reminder - kept as it is.** The dot next to the menu
      bar icon and the relabelled tray item were judged noticeable enough
- [ ] **Build 6.** From main once #19 and #25 are in: notification and staleness
      fixes, Sign in with Apple, the larger icon. Then bump the
      `/download/macos` redirect (runbook step 8)
- [x] **Notarize in CI - decided against.** Publishing needs three secrets in
      one place: the Developer ID private key, notarization credentials, and
      the Sparkle EdDSA key. That last one is unrecoverable - if it leaks,
      anyone can sign an update every installed copy accepts and installs. Not
      worth that to replace one local command. A workflow that *verifies* a
      published feed (signature, checksums, feed matches release) is still
      worth having; publishing stays manual

## Windows: next

**Ships through the Microsoft Store**, decided 2026-09-19. Registration is free
for Individual and Company accounts via https://storedeveloper.microsoft.com -
that entry point specifically; Partner Center and Visual Studio still route to
the paid legacy flow. The Store signs the package and handles updates, which
avoids a code-signing certificate and removes the WinSparkle half of the
updater. Unsigned direct download is worse than it sounds: SmartScreen
reputation accrues per certificate, and unsigned it accrues per file hash, so
every release and every auto-update re-triggers the warning.

CI already builds Windows on `windows-latest`, so no Windows machine is needed
to package - but everything below marked "verify" does need one.

- [ ] **Clipboard counter: two copies in a row from GhostCopy's own window
      read as one** (verify, then fix). `ClipboardChangeCount()` in
      `windows/runner/flutter_window.cpp` ignores a sequence change while the
      same in-process window owns the clipboard, to hide OLE's delayed
      rendering. So a second Ctrl+C in the Spotlight field, or a second smart
      action copy, never moves the counter: auto-send skips it and smart
      receive does not date it. The deeper fix is `OleFlushClipboard()` after
      each GhostCopy write, which renders every format up front so the raw
      `GetClipboardSequenceNumber()` only moves on real changes and the owner
      check can go. Found in the PR #19 review, 2026-09-24
- [ ] **Pick the Store account type before signing up.** Individual means
      distribution NOT in relation to a business, so a released product points
      at Company - a DUNS number or business documents, and a work email on the
      organisation's domain (contact address is anchored.site, product is
      ghostcopy.app). **Individual cannot be converted to Company later.**
- [ ] **Package as MSIX** for the Store, replacing the Inno Setup script.
      `msix_config` in `pubspec.yaml` is a placeholder: identity and publisher
      come from Partner Center once the name is reserved, and it needs
      `store: true`. Three things the app registers itself today break inside
      a package, because MSIX virtualizes HKCU and AppData writes - checked
      against the code 2026-09-22, not yet on a machine:
  - [ ] **`ghostcopy://` sign-in callback.** `_registerWindowsUrlScheme` in
        `lib/main.dart` writes `HKCU\Software\Classes\ghostcopy` with
        `reg.exe`; packaged, that lands in the package's private hive and
        Google sign-in never comes back. Declare `protocol_activation:
        ghostcopy` in `msix_config` and skip the registry write when packaged
  - [ ] **Launch at startup.** The registry Run key is virtualized, and
        launch_at_startup's MSIX mode is no better: it drops a Startup-folder
        shortcut to the versioned `WindowsApps` exe path, which every Store
        update moves. Needs a `startup_task` in `msix_config` plus the WinRT
        `StartupTask` API (`RequestEnableAsync`) behind a method channel in
        the Windows runner - the same shape as the macOS fix
  - [ ] **"Send with GhostCopy" in Explorer.** `_registerWindowsContextMenu`
        writes `HKCU\Software\Classes\*\shell`, also virtualized. The
        packaged route is `desktop4:FileExplorerContextMenus`, which needs a
        native COM `IExplorerCommand` DLL (msix's `context_menu` config).
        Decide whether it is worth that, or whether the Windows share target
        covers it
- [ ] **Store submission**
- [ ] **Tray menu frameless leak - fixed 2026-09-22, verify.** `_showTrayMenu`
      calls `setAsFrameless()`, and in window_manager's Windows code only
      `setTitleBarStyle` clears that flag. Until then `WM_NCCALCSIZE` hands the
      whole window to Flutter, so after the first tray right-click the
      Spotlight lost its resize borders and came back ~16px wider and 8px
      taller. `WindowService.showSpotlight` now restores
      `TitleBarStyle.hidden` (buttons hidden) on Windows. Check: right-click
      the tray, then open Spotlight - same size as before, edges resize
- [ ] **Icons (look only).** All Windows `.ico` files are current - the
      generator was re-run 2026-09-22 and reproduced them byte for byte. They
      have just never been looked at on a real taskbar, light and dark
- [ ] **System notifications (Windows half).** Toast and its Action Center
      entry, Game Mode suppression, tap opens/copies, fresh-install permission.
      Received clips never notified on any desktop until 2026-09-22 - the sync
      service was built without its notifier - so this is the first real test
- [ ] **Clipboard staleness (verify).** New native channel in
      `windows/runner/flutter_window.cpp` answers `changeCount` from
      `GetClipboardSequenceNumber()`, counting a change only when the
      clipboard changes hands (so OLE delayed renders do not count), and
      pushes "changed" on every `WM_CLIPBOARDUPDATE` so the smart watch runs
      no timer on Windows. Written but not yet compiled. Check: the app builds; with auto-receive on smart,
      copy something in another app, send a clip from the phone within the
      stale window - it is NOT copied and a "Copy" notification appears
      instead; after the window it is
      copied; two clips sent back to back are both copied; copying from
      GhostCopy's history also counts; pasting an auto-copied clip into Word
      does NOT make the next clip wait. Auto-send now skips reading an
      unchanged clipboard on Windows too, via the same counter, and a copy
      made while a clipboard manager briefly holds the clipboard open is
      still auto-sent a tick or two later
- [ ] **Launch at startup (verify).** Uses the package's registry path on
      Windows, unlike macOS; check it survives a reboot
- [ ] **Encryption after reinstall/account switch.** Install over an existing
      passphrase, sign into the same account, and confirm encrypted history
      appears without toggling encryption (flutter_secure_storage's Windows
      backend)
- [ ] **Resource baseline.** One Task Manager sample idle in the tray and one
      with the window open, recorded like `docs/macos-performance.md`, before
      changing lifecycle or realtime services
- [ ] Sign in, sign out and account upgrade

## iOS: open

- [ ] **TestFlight.** Signing is `Apple Development`; TestFlight needs Apple
      Distribution. `aps-environment` reads `development` in the entitlements;
      the App Store export switches it, and the Firebase APNs key covers both
- [x] **Privacy manifests** - `ios/Runner` and `ios/ShareExtension` now ship
      `PrivacyInfo.xcprivacy` declaring their UserDefaults use; confirmed in a
      release build. Branch `ios/app-store-prep`
- [ ] **In-app account deletion - built, deploy and test it.** Branch
      `feat/account-deletion`. Settings > Delete Account (iOS and Android,
      signed-in accounts), backed by the `delete-account` Edge Function: it
      deletes the auth user - clips, devices, tokens cascade, the clipboard
      trigger queues stored files for R2 removal, the passphrase backup lives
      in the user record - and for Apple accounts first exchanges a fresh
      authorization code (the app asks Apple once more) and revokes the Apple
      token, as Apple requires. A failed revocation does not block deletion.
      The device then wipes its copy (Keychain passphrase, caches, staged clip)
      and lands on a guest account, as after sign-out.
  - [ ] **Set the function secret** `APPLE_PRIVATE_KEY` to the `.p8`
        contents, or Apple accounts are deleted without revocation (logged)
  - [ ] Deploys with the merge to `main` (deploy workflow covers
        `supabase/functions/**`)
  - [ ] Test on the iPhone with an email account and an Apple account; check
        Supabase > Users and the R2 bucket afterwards
  - [ ] Desktop has no delete button yet - add to the settings panel if
        wanted; the website page tells desktop-only users to email
- [x] **Account deletion web page** for Google Play's data-deletion URL:
      `website/delete-account.html`, linked from the privacy policy
- [ ] **Sign in with Apple - built, test it.** Branch `ios/sign-in-with-apple`.
      Needed on every platform, not just iOS: an account made on an iPhone
      with Apple (and Hide My Email) has no password, and QR linking only
      brings a phone into a desktop's account, never the reverse - so a new
      computer has no other way in.
      - **iOS: native.** "Continue with Apple" above Google on the welcome
        screen; Sign Up links in place (`linkIdentityWithIdToken`), Login
        switches accounts with the guest-clips warning. SHA-256 nonce.
      - **macOS: native** too - the system sheet with Touch ID and the Mac's
        Apple ID, no browser. Entitlement in both macOS entitlement files;
        the profile refreshed with `-allowProvisioningUpdates` and
        `verify-app.py` now refuses a release whose profile lacks it.
      - **Windows: browser flow**, the same path Google uses (Supabase ->
        `ghostcopy.app/auth-callback` -> `ghostcopy://auth-callback`), button
        in the Spotlight auth panel.
      - **Android: not yet.** The browser flow's calls return when the browser
        opens, and the mobile welcome screen would go on to `onAuthComplete`
        with the old session. Needs `_handleProviderAuth` to wait for the
        non-anonymous session from `onAuthStateChange` before finishing, then
        a device test. Do it in the Android phase.
      - **Setup:** Supabase Apple provider Client IDs
        `com.ghostcopy.ghostcopy,com.ghostcopy.web`; Services ID
        `com.ghostcopy.web` with domain `xhbggxftvnlkotvehwmj.supabase.co`
        and return URL `https://xhbggxftvnlkotvehwmj.supabase.co/auth/v1/callback`.
        Key ID `Y8NRLTKXG3`, Team `R9TKT8U45R`; the `.p8` is kept offline.
      - **Secret Key expires every 6 months.** `dart run
        tool/apple_client_secret.dart <AuthKey.p8>` prints a new one and its
        expiry. Lapsing breaks desktop Apple sign-in silently (iOS is native
        and unaffected) - keep a calendar reminder
      - Check on devices: Sign Up keeps the clips, Login switches, cancel
        leaves the screen as it was, Hide My Email works, desktop round trip
- [ ] **Export compliance.** The app runs its own AES-256-GCM and
      PBKDF2-HMAC-SHA256 in Dart, on top of the OS's, so it is not the
      "Apple's encryption only" exempt case - do not set
      `ITSAppUsesNonExemptEncryption` to NO. Answer the questionnaire on the
      first upload ("standard algorithms in addition to the OS"), then set
      the Info.plist key(s) it points to so later uploads skip it
- [x] **Privacy policy** matches the app now (R2 file storage, auto-send,
      webhook, Obsidian) - `website/privacy.html`, deploys on merge to `main`
- [x] **Listing drafted** in `docs/app-store-listing.md`: store text, age
      rating, App Privacy answers, export compliance, review notes
- [x] Display name was "Ghostcopy" on the home screen and in permission
      prompts; now GhostCopy
- [ ] **Demo account for App Review** - no guest path on the iOS welcome
      screen and sign-up waits on a confirmation email. Create one on a real
      inbox, no passphrase, a few clips, the Mac linked. See the listing doc
- [ ] **Screenshots** (6.9" iPhone, 13" iPad) - taken with the demo account
      once it exists; needs it signed in on the simulator
- [ ] **Review screen recording** - Mac and iPhone round trip, shot list in
      the listing doc
- [x] Privacy policy and listing updated for Apple sign-in and in-app
      account deletion

- [ ] **Foldable iPhone check - later, not blocking TestFlight.** A foldable
      iPhone is expected around late October 2026; its simulator is in the
      Xcode beta, not in the installed Xcode 27.0. The layout is likely covered
      already: the one/two-pane split in `mobile_main_screen.dart` keys on
      aspect ratio in shared Flutter code (built for the Pixel Fold in
      `554ed43`), and the app already targets iPad. Install the beta alongside,
      never over, the release Xcode - uploads should stay on the release one -
      and check folded, unfolded, and a live fold/unfold mid-compose
- [ ] **Keychain migration on device.** The `first_unlock` migration
      (`lib/services/impl/keychain_accessibility.dart`) still needs confirming
      on a phone holding a passphrase written by an older build - a fresh
      install cannot show it. Simulator Keychain items survive uninstalls,
      which disguised this last time
- [ ] **Device-name entitlement.** Request
      `com.apple.developer.device-information.user-assigned-device-name` from
      Apple (developer.apple.com, Contact -> Request). Cosmetic only: device
      rows already stay unique via the `identifierForVendor` suffix, so a phone
      reads "iPhone 15 Pro - a1b2c3d4" instead of "Subai's iPhone". The case
      for it: clips are labelled by sending device and settings lists them, so
      the owner's name for a device is the point. If granted, add the key to
      `ios/Runner/Runner.entitlements`; `initializeDeviceName()` already
      prefers `ios.name`
- [ ] **`primary` as a foreground is 4.44:1 on `surface`**, just under AA.
      Used as a foreground in ~104 places: either the token moves, or call
      sites move to `accentText` (8.98:1) one at a time, as the email templates
      did
- [ ] `flutter logs` returns nothing from a profile build on device. The
      background isolate is only observable by writing files to the app
      container and reading them with `devicectl device info files`

## All platforms

- [ ] **Check the email confirmation link on macOS and iOS.** The deep-link
      predicate in `lib/main.dart` accepts `token_hash` links, but on the
      AppLinks route supabase_flutter hands them to `getSessionFromUrl`,
      which in PKCE mode wants a `code` and may throw "No code detected". Only
      the Windows command-line route calls `verifyOTP`. Sign up with a fresh
      email on the Mac and on the iPhone and tap the link; if it fails, route
      AppLinks through `_handleDeepLinkArgs` (`detectSessionInUri: false`) so
      there is one callback handler. Found in the PR #19 review, 2026-09-24
- [ ] **Do not disable legacy API keys** until every released build carries
      the publishable key. It is compiled in; an update is the only way to
      change it, which is why the macOS updater had to land first
- [ ] Version scheme: `1.0.0+N`, build number bumped per release (at 5 now).
      TestFlight and Play reject a duplicate build number, so keep it
      monotonic across platforms
- [ ] **Sentry in the client, before the first shipped build.** A hard
      ordering constraint, not a preference: it has to be compiled into the
      build that goes out. Ship without it and the first real crashes are
      invisible, and seeing them costs another signed, notarized release per
      platform. Scrub clipboard content from every event before sending. See
      the monitoring section below.

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
application side. What is left is outside the repo.

### Now - dashboard only, no code, no dependency on any platform

Worth being precise about what the exposure actually is, because on the plans
this project is on it is mostly **not** a bill. Every quota below should be
re-checked against current provider docs rather than trusted from here.

- [ ] **Supabase (free plan).** Cannot be charged, so there is no bill to cap -
      but that inverts the risk rather than removing it. Exceeding free limits
      gets a project restricted or paused, and a paused project is the app
      fully down for every user on every platform. That is worse than an
      unexpected invoice, and it is the one to watch around a launch. Set usage
      notifications on Database Egress and Database Size, and know in advance
      what upgrading costs, so the answer to an outage is a plan rather than a
      decision made under pressure
- [ ] **Google Cloud / Firebase.** FCM messaging itself is free and not
      metered, so "essentially free" holds for what this app uses it for.
      Confirm which plan the project is on: on Spark nothing can bill, on Blaze
      other services can. If Blaze, set Budgets & Alerts at 50/80/100%
- [ ] **Cloudflare R2.** The only place real money can leak. The free
      allowance is generous, but overage bills once a payment method is on
      file, and R2 has no hard spend cap - notifications are the only guard, so
      configure them on storage capacity and Class A/B operation counts. Worth
      confirming what "limits already on it" means today: a Cloudflare
      notification is an alert after the fact, not a ceiling
- [ ] **Cloudflare 5xx rate spike notification.** Free, and the fastest signal
      that image sync is broken for everyone rather than one device

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


## Parallel track: Google Play

Play Console account purchased 2026-09-15. Full path:
[`left_TO_DO/PLAY_STORE_SETUP.md`](../left_TO_DO/PLAY_STORE_SETUP.md)

Front-load this. A new personal account must run a closed test with 20 testers
for **14 continuous days** before it can apply for production, so the clock
should start as early as a build allows.

- [ ] Generate the upload keystore, add `android/key.properties` (Gradle is
      already wired for it)
- [ ] `flutter build appbundle --release`, verify it is not debug-signed
- [ ] Create the app in Console; privacy policy, data safety, content rating
- [ ] Upload to closed testing and recruit 20 testers — **starts the 14 days**
- [ ] **Android Apple sign-in.** Hidden on Android for now. Apple is the
      browser flow there; AuthService already waits for the callback's
      session (`awaitBrowserSession`), so no UI-level wait is needed. Give the
      welcome screen a Cancel while it waits (the desktop auth panel has one),
      then show the button (remove the `Platform.isIOS` gate) and test on a
      device. Supabase and Apple Developer need nothing more - it uses the
      same Services ID as Windows

## Later: clipboard export and import

Signing into an existing account from a guest session leaves the guest's clips
behind, because they belong to the anonymous user_id. Merging accounts was
rejected - a lot of conflict handling for a rare case. The app warns before it
happens, and dormant guest accounts expire after 90 days
(`20260916220000_expire_dormant_anonymous_accounts.sql`). Export/import answers
it better, and also covers backups and leaving without losing anything.

- [ ] Decide the format first - it has to outlive everything else. Content
      type, timestamps, device origin, and whether encrypted clips travel
      encrypted or are decrypted on export
- [ ] Export the signed-in user's clips to a portable file
- [ ] Import that file into another account
- [ ] Files and images: inline them, or a manifest plus a folder
- [ ] Does not need to be instant. A queued job that emails or exposes a
      signed download is cheaper and sidesteps timeouts on large histories

## Later: AI assistant integration via MCP

Let users ask an assistant to "send this to my phone" or send a generated file
to another device through GhostCopy on macOS and Windows. Local MCP first, for
Claude Desktop and ChatGPT/Codex, reusing GhostCopy's sending services, account
and encryption. A CLI can follow on the same implementation.

- [ ] Tools to list devices, send text or links, and send files
- [ ] Target a device by ID, resolving names such as "my phone"
- [ ] Opt-in connection; clipboard-history access a separate permission
- [ ] Report queued/sent accurately; only report received with a delivery
      acknowledgement
- [ ] Straightforward setup, verified on both desktop platforms
- [ ] Trial "send this to my phone" before expanding scope

## Later: widget extraction

Left over from the February ViewModel refactor (Phases 1.1 and 1.2 done).

- [ ] Shared `StaggeredHistoryItem` widget, platform chips, and the remaining
      duplicated widgets between spotlight and mobile

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
