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

- [ ] **Launch at startup - fixed 2026-09-22, needs a hand check.** The
      `launch_at_startup` package ships no macOS code and expects the app to
      answer its method channel. Nothing did, so the Settings toggle saved the
      preference and never registered a login item (the
      MissingPluginException was swallowed in `AutoStartService`).
      `macos/Runner/LaunchAtStartup.swift` now answers it with
      `SMAppService.mainApp`. Check: toggle on, confirm GhostCopy appears in
      System Settings > General > Login Items, log out and back in; toggle off
      and confirm it is removed. Needs an installed build - a copy run from
      `build/` registers that path instead
- [ ] **Decide whether the gentle update reminder is too quiet.** A scheduled
      check shows only a dot next to the menu bar icon and relabels the tray
      item; someone who never opens that menu never updates
- [ ] Later, optional: notarize in CI. Releases are cut locally with
      `installer/macos/build-release.sh` today; CI stops at
      `flutter build macos --release`

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
      entry, Game Mode suppression, tap opens/copies, fresh-install permission
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
      Distribution
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

- [ ] **Do not disable legacy API keys** until every released build carries
      the publishable key. It is compiled in; an update is the only way to
      change it, which is why the macOS updater had to land first
- [ ] Version scheme: `1.0.0+N`, build number bumped per release (at 5 now).
      TestFlight and Play reject a duplicate build number, so keep it
      monotonic across platforms

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
