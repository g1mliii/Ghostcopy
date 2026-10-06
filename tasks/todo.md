# Current Work

## Windows

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

Worth knowing rather than doing: **a full-trust MSIX redirects AppData writes
only for files that did not already exist.** Measured during the sideload, on
a machine that already had `%APPDATA%\com.ghostcopy`: the packaged app wrote
straight to the real folders and the container's `LocalCache` stayed empty -
so uninstalling left the session, settings, passphrase and caches behind. Not
yet re-measured on a clean profile. Either way a packaged build now keeps its
data in the package's own `LocalState` and
`LocalCache` explicitly (`PackagedAppData`, which moves an earlier version's
AppData over on first launch), and Windows deletes those with the package.
An unpackaged dev build still uses `%APPDATA%\com.ghostcopy`, so the two no
longer share a session. Left behind on uninstall: one Credential Manager entry,
flutter_secure_storage's key for a data file that is deleted with the package.

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
      `ITSAppUsesNonExemptEncryption` to NO. App Store Connect's App
      Encryption Documentation may ask for an upload (e.g. a French ANSSI
      declaration if France is enabled, or a US classification); make sure
      whatever it asks for is filed, then add the Info.plist key(s) it points
      to so later uploads skip it
- [ ] **Keychain migration on device.** The `first_unlock` migration
      (`lib/services/impl/keychain_accessibility.dart`) still needs confirming
      on a phone holding a passphrase written by an older build - a fresh
      install cannot show it. Simulator Keychain items survive uninstalls,
      which disguised this last time
- [ ] **Device-name entitlement - requested, awaiting Apple's approval.**
      `com.apple.developer.device-information.user-assigned-device-name`.
      Cosmetic: device rows already stay unique via the `identifierForVendor`
      suffix ("iPhone 15 Pro - a1b2c3d4"). Once granted, add the key to
      `ios/Runner/Runner.entitlements`; `initializeDeviceName()` already
      prefers `ios.name`
- [ ] `flutter logs` returns nothing from a profile build on device. The
      background isolate is only observable by writing files to the app
      container and reading them with `devicectl device info files`

## All platforms

- [ ] **Tapping the same email sign-in link twice** gives the "already used"
      message, not a raw error. The crash it used to cause is fixed
      (`d37141f`); the message itself has not been checked

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
