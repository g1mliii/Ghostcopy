# Current Work

## Windows

- [ ] **Store updates pause ~92 s at "Almost done".** Seen on both Store
      updates so far (1.0.10 -> 1.0.16 -> 1.0.17). The download is seconds;
      the wait is a fixed timeout while the COM Surrogate hosting the
      "Send with GhostCopy" verb fails to shut down. Evidence and the next
      test (restart Explorer, do not right-click a file, then update) are in
      [`docs/windows-store-update-investigation.md`](../docs/windows-store-update-investigation.md)
- [ ] **Relaunch after an update.** A Store update closes GhostCopy and
      nothing starts it again, so the tray app is gone until the next login.
      `RegisterApplicationRestart` at startup is Microsoft's documented way
      for a full-trust MSIX app; confirm it on a real Store update
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
- [ ] **Verify the second-launch fix.** Clicking the app while it is already
      running opens the window - it never did before. Check sign-in still
      completes (same delivery path), and that "Send with GhostCopy" sends
      WITHOUT popping the Spotlight open.
- [ ] **Decide whether Windows needs an update signal in the UI.** macOS has
      the dot by the menu bar icon because Sparkle needs the user to act. The
      Store updates silently, so probably nothing - but make it a decision.
- [ ] If a clip is ever slow again but the *next* one is instant, the death
      was silent (no status to react to) and the evidence-based rejoin
      caught it. The next lever then is opting the process out of Windows
      power throttling (EcoQoS) - the root rather than the recovery. Not
      done pre-emptively: it fights the OS's power management and sits
      beside the working-set trim.
- [ ] **Icon: the mark's bounding box is centred to the pixel but its mass is
      not** - the centroid sits 5.9px left and 59px high of centre at 1024
      (0.6% and 5.8%). Optical centring would shift it to match, but that
      moves the iOS, macOS and Android icons too, including ones already
      through review, so it is a deliberate call rather than a bug fix

Worth knowing rather than doing: **AppData is NOT redirected for a full-trust
MSIX.** Measured during the sideload: the packaged app wrote straight to the
real `%LOCALAPPDATA%` and the container's `LocalCache` stayed empty, so a
packaged and an unpackaged build on the same machine share
`%APPDATA%\com.ghostcopy` - the same session, settings and passphrase.
Anything that assumes per-package state is wrong, and a Store install is not
isolated from a dev build.

## iOS: open

- [ ] **Share extension rewrite - confirm on device** (merged to main in
      `7d1f6d2`, `ios/ShareExtension/ShareViewController.swift`).
      The package's loader asked a document for `public.text`, got a file URL
      back and silently never finished, so sharing a .txt/.ips hung the sheet.
      Attachments now load in our own code: a file on disk is sent as a file,
      only real text as text, and every share completes (60 s backstop).
      Written on Windows, so check it compiles on the Mac first. On device,
      share a .txt from Files, a Jetsam log from Analytics Data, a photo, a
      Safari page, a message from Messages, and two files at once - and
      confirm each arrives as the right kind of clip
- [ ] **Offline history** (`HistoryDiskCache`, merged in `52df3d2`): on a
      phone, open once online, then in airplane mode force-quit and reopen -
      the list shows with "saved · offline" and a text clip copies. Also sign
      out and back in as someone else offline: nothing of the first account
      shows. Files and images only open offline if they were opened before
      (MediaDiskCache)
- [ ] **Export compliance.** The app runs its own AES-256-GCM and
      PBKDF2-HMAC-SHA256 in Dart, on top of the OS's, so it is not the
      "Apple's encryption only" exempt case - do not set
      `ITSAppUsesNonExemptEncryption` to NO. Answer the questionnaire on the
      first upload ("standard algorithms in addition to the OS"), then set
      the Info.plist key(s) it points to so later uploads skip it
- [ ] **Screenshots** (6.9" iPhone, 13" iPad) - taken with the demo account
      once it exists; needs it signed in on the simulator
- [ ] **Review screen recording** - Mac and iPhone round trip, shot list in
      the listing doc
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

- [ ] **Tapping the same email sign-in link twice** gives the "already used"
      message, not a raw error. The crash it used to cause is fixed
      (`d37141f`); the message itself has not been checked
- [ ] **Do not disable legacy API keys** until every released build carries
      the publishable key. It is compiled in; an update is the only way to
      change it, which is why the macOS updater had to land first

## Monitoring, error tracking and cost guards

From a monitoring plan reviewed 2026-09-22.

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

## Next update: a pin for the Spotlight

Decided 2026-09-26 to follow the Store submission, which is done - it is new
behaviour and wants its own testing pass. Store updates are free and
automatic.

Auto-hide on blur is right for a Spotlight-style tool and matches Spotlight,
Alfred, Raycast and PowerToys Run. But it fights three workflows a clipboard
app actually has: copying something in another app and coming back to send
it, dragging a file in from Explorer or Finder, and keeping history visible
while working. All three need the window to survive losing focus.

Chosen shape: **a pin toggle in the window's own header**, not a setting. It
is discoverable at the moment it is wanted - the user is looking at the
window when the auto-hide annoys them - and it leaves the default behaviour
alone, so the ephemeral character survives. A Settings switch fails exactly
the person it is meant to help, who would have to go looking for it.

- [ ] Pin toggle in the Spotlight header, on Windows and macOS
  - [ ] Pinned means `onWindowBlur` returns early - and that has to skip the
        whole tray-optimization block, not just `hideSpotlight`. That block
        clears the image cache, trims media and schedules the working-set
        trim, none of which is right for a window that is still on screen
  - [ ] Decide whether the pin persists across launches. Leaning yes, through
        SettingsService - someone who pins it probably wants it pinned
        tomorrow - but keep the *control* in the window rather than adding a
        Settings row, or it becomes the setting this was chosen over
  - [ ] The header is on a 400px panel; check the icon does not crowd the
        close button
- [ ] **Separately, and worth doing whether or not the pin lands: blur
      discards the composer.** `onWindowBlur` clears the text controller and
      the clipboard payload when there is an attachment, so clicking away
      mid-compose loses what was typed or attached. That is a sharper problem
      than the window closing, and it is a bug rather than a preference.

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
