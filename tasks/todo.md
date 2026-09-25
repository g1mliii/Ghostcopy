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

- [ ] **Sandbox - only if the Mac app goes to the Mac App Store.** Required
      there, optional for Developer ID. It would mean Sparkle's XPC
      services (or dropping Sparkle for store updates), an Obsidian folder
      picker with security-scoped bookmarks, and migrating preferences into
      the container; it would also bring back the native Apple sign-in sheet

## Windows: next

**Ships through the Microsoft Store**, decided 2026-09-19. Registration is free
for Individual and Company accounts via https://storedeveloper.microsoft.com -
that entry point specifically; Partner Center and Visual Studio still route to
the paid legacy flow. Re-checked 2026-09-25: Company became free in May 2026
(sign-up with an Entra ID work account), Individual in September 2025 (ID and
selfie). Publishing is free; Microsoft only shares revenue from paid apps and
in-app purchases, which GhostCopy has none of. The Store signs the package and handles updates, which
avoids a code-signing certificate and removes the WinSparkle half of the
updater. Unsigned direct download is worse than it sounds: SmartScreen
reputation accrues per certificate, and unsigned it accrues per file hash, so
every release and every auto-update re-triggers the warning.

CI already builds Windows on `windows-latest`, so no Windows machine is needed
to package - but everything below marked "verify" does need one.

- [ ] **AppData is NOT redirected for a full-trust MSIX**, contrary to the
      note this file used to carry. Measured during the sideload: the packaged
      app wrote its sentry-native database straight to the real
      `%LOCALAPPDATA%` and the container's `LocalCache` stayed empty, so the
      packaged and unpackaged builds share `%APPDATA%\com.ghostcopy` - the
      same session, settings and passphrase. Harmless for the crash database,
      but it means the sideload test was never isolated from the dev build,
      and anything that assumes per-package state is wrong
- [ ] **WNS is not used and needs no setup.** The Partner Center WNS/MPNS page
      applies to apps receiving cloud push through Windows Push Notification
      Services. GhostCopy desktop has no FCM and no push: it holds a Supabase
      Realtime socket and raises a *local* toast through
      flutter_local_notifications. Nothing to configure, and it has no bearing
      on the account type
- [ ] **Regenerate the icons on a Mac.** `tile()` in
      `tool/generate_brand_assets.py` seated the mark one pixel left and high
      at any size where `px - int(px * inset)` is odd, because the floor in
      `// 2` gave the spare pixel to the right and bottom. Measured on the
      shipped assets: 32px had 9px of padding left and 10 right, 256px had 73
      and 74. One pixel is 3% of a 32px icon, which is the "not centred, too
      far to the left" in the context menu and the tray. Fixed in the
      generator and the arithmetic checked at every shipped size - 3 of 13
      were off before, none after - but Cairo will not load on Windows, so the
      PNG and ICO files still carry the old placement. Re-run
      `DYLD_LIBRARY_PATH=/opt/homebrew/lib python3 tool/generate_brand_assets.py`
      on the Mac and commit what it writes
  - Separately, and NOT fixed: the mark's bounding box is centred to the pixel
    but its mass is not - the centroid sits 5.9px left and 59px high of centre
    at 1024 (0.6% and 5.8%). Optical centring would shift it to match, but
    that moves the iOS, macOS and Android icons too, including ones already
    through review, so it is a deliberate call rather than a bug fix
- [ ] **The logo in the Windows toast looks warped.**
      `WindowsInitializationSettings` in
      `lib/services/impl/notification_service.dart` takes an optional
      `iconPath` and is not given one, so Windows falls back to deriving an
      icon. Passing an explicit square PNG needs a real file path, and the
      asset lives inside `data/flutter_assets`, so it has to be resolved or
      copied out at runtime. Re-check first with the now-rounded icons: in a
      package Windows uses Square44x44Logo, which is regenerated from
      `app_icon.png`, so this may already be fixed
- [ ] **Unattributed native crash, 2026-09-25 19:59 UTC.**
      `EXCEPTION_ACCESS_VIOLATION_READ / 0x10` with `SetWaitableTimer` as the
      only named frame - a null-ish dereference. It arrived unsymbolicated
      because the shipped build's PDBs had not been uploaded (see
      `tasks/lessons.md`); they have been since, and Sentry reprocesses native
      events when symbols arrive late, so check whether that issue resolved.
      Do not theorise from the frame name alone: on Windows the Dart VM's own
      event handler uses waitable timers, so it is as likely to be teardown as
      anything in this app. Wait for a symbolicated recurrence.
- [ ] **Verify the clipboard counter change by hand.** `OleFlushClipboard`
      replaced the owner check, and the two halves pull against each other -
      none of it is covered by tests:
  - [ ] Two copies in a row in the Spotlight field are BOTH auto-sent (the
        bug the change fixes)
  - [ ] Two smart-action copies in a row are both seen
  - [ ] Pasting an auto-copied clip into Word does NOT make the next clip
        wait (what the old owner check protected; most likely to regress)
  - [ ] Auto-receive on smart: copy elsewhere, send from the phone inside the
        stale window - NOT copied, "Copy" notification instead; after the
        window, copied
  - [ ] Two clips sent back to back are both copied
  - [ ] Copying from GhostCopy's own history counts
  - [ ] A large image or 10 MB file still copies without a visible stall
- [ ] **Verify the thumbnail cache by hand.**
  - [ ] Cold launch on Windows, and on both mobile platforms
  - [ ] Save, share and drag-out still produce the FULL image, not the
        thumbnail - the regression this project has had before
  - [ ] A full-size preview is not a blurry upscale
  - [ ] Encrypted clips still render; deleting a clip drops its thumbnail;
        signing out wipes the cache
- [ ] **Verify the memory work by hand.**
  - [ ] Hotkey after 2-3 hours idle *while the machine is in normal use*, so
        the trimmed pages have actually been reclaimed. An idle machine
        evicts nothing and proves nothing
  - [ ] A clip sent from the phone after 30+ minutes idle still notifies and
        auto-copies
  - [ ] Tray menu after a long idle, and that it now draws in front of the
        taskbar flyout
  - [ ] Mobile: background the app, reopen, list appears immediately; a push
        still arrives after a long background
- [ ] **Verify the second-launch fix.** Clicking the app while it is already
      running opens the window - it never did before. Check sign-in still
      completes (same delivery path), and that "Send with GhostCopy" sends
      WITHOUT popping the Spotlight open.
- [ ] **Windows updates: cannot be tested until published.** A sideloaded
      package does not auto-update; only a Store-installed one does. After
      the first release, submit a higher `msix_version` and confirm it
      arrives (Store > Library > Get updates forces it).
- [ ] **Decide whether Windows needs an update signal in the UI.** macOS has
      the dot by the menu bar icon because Sparkle needs the user to act. The
      Store updates silently, so probably nothing - but make it a decision.
- [ ] **Store submission:** the listing text (reuse the App Store one, naming
      Windows rather than Mac where it applies), screenshots, and the Store's
      own privacy and age-rating answers - the privacy answers must include
      Sentry crash reports, as on the App Store

## iOS: open

- [ ] **TestFlight - 1.0.0 (7) uploaded 2026-09-25**, internal testing only
      until the Sentry build. Verified in the IPA: Apple Distribution,
      aps-environment production, App Group and Sign in with Apple on both
      targets. Left: answer Missing Compliance, add the Info.plist key it
      points to, confirm production push on the TestFlight install. Upload
      warned "Upload Symbols Failed" for objective_c.framework - its dSYM
      matches the shipped UUID but Flutter copies it into the archive twice;
      only affects symbolication inside that bridge, and Sentry uploads its
      own. Earlier notes: signing was `Apple Development`; TestFlight needs
      Apple Distribution. `aps-environment` reads `development` in the entitlements;
      the App Store export switches it, and the Firebase APNs key covers both.
      Confirm in Firebase (Project settings > Cloud Messaging > Apple app)
      that it is an APNs Authentication Key (.p8), not a development-only
      certificate, or push stops in App Store builds
- [ ] **Decide: iPad at launch, or iPhone-only.** The app targets iPad, so the
      listing needs 13" iPad screenshots and review tests it there. Dropping
      iPad for 1.0 (TARGETED_DEVICE_FAMILY = 1) skips both; it can come back
      in an update
- [ ] **Export compliance.** The app runs its own AES-256-GCM and
      PBKDF2-HMAC-SHA256 in Dart, on top of the OS's, so it is not the
      "Apple's encryption only" exempt case - do not set
      `ITSAppUsesNonExemptEncryption` to NO. Answer the questionnaire on the
      first upload ("standard algorithms in addition to the OS"), then set
      the Info.plist key(s) it points to so later uploads skip it
- [ ] **Demo account for App Review** - no guest path on the iOS welcome
      screen and sign-up waits on a confirmation email. Create one on a real
      inbox, no passphrase, a few clips, the Mac linked. See the listing doc
- [ ] **Screenshots** (6.9" iPhone, 13" iPad) - taken with the demo account
      once it exists; needs it signed in on the simulator
- [ ] **Review screen recording** - Mac and iPhone round trip, shot list in
      the listing doc
- [ ] **Photos over 10 MB shared from the share sheet are refused.** The
      gallery picker now scales a too-large JPEG/PNG/WebP down
      (`lib/utils/image_shrink.dart`), but a photo shared into GhostCopy goes
      through the shared-files path, which only checks the size. Route it
      through the same shrink
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

- [ ] **Nothing retries auth after a failed launch.** `startAuthAndDevice` in
      `lib/main.dart` now keeps a failed sign-in from taking the tray icon and
      hotkey down with it (2026-09-25), so the app comes up - but it comes up
      with no session and nothing asks again. `AuthService.initialize()` leaves
      `_initialized` false when it throws, so it is safe to call again; what is
      missing is a caller. Launching offline therefore gives a running app that
      stays signed out until it is restarted. Options: retry on the first
      Spotlight open, or listen for connectivity. Decide before the Store
      build - it is the difference between "opened the laptop on a train" and
      "the app is broken"

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
