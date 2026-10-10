# GhostCopy on CachyOS / KDE Plasma Wayland

This branch produces an x86-64 Linux test build with the desktop integrations
below. The Flutter window uses XWayland; background clipboard reads use native
Wayland data-control through wl-paste, and global shortcuts use KDE's portal.
Real Plasma session acceptance remains to be done on CachyOS. The window still
uses XWayland. Installed builds support automatic update checks and confirmed
download/install; live updates require the Linux release feed to be published.

## Install the test build

Install the runtime prerequisites (many will already be installed):

```sh
sudo pacman -S --needed gtk3 libsecret keybinder3 libayatana-appindicator wayland wl-clipboard xorg-xwayland xdg-desktop-portal-kde desktop-file-utils python
```

Secure storage also needs an unlocked Secret Service provider. KDE Wallet can
provide it when configured; GNOME Keyring is another option. The libsecret
library alone is not a running secret service. Run the included diagnostics
without reading or printing clipboard contents:

```sh
bash linux_doctor.sh
```

Extract `ghostcopy-linux-x64.tar.gz`, open a terminal in its extracted directory,
quit any previous GhostCopy instance, and install **without sudo**:

```sh
python3 install_linux.py --bundle bundle
```

Launch **GhostCopy** from Plasma's application menu. Approve its global shortcut
request when KDE asks. Change the actual binding through GhostCopy Settings →
Global shortcut → Configure. KDE owns that binding. Configure retries if you
cancel the initial request; the tray Open action works without a shortcut.

Installation copies the bundle to `~/.local/lib/ghostcopy`, installs the app and
Dolphin menu entries, and registers `ghostcopy://` for browser sign-in. It adds
`ghostcopy-desktop`, `ghostcopy-send`, and the `ghostcopy` CLI to `~/.local/bin`.
Add that directory to your shell PATH if the CLI is not found. Desktop launchers
use absolute paths. Restart Dolphin if its new action is not visible.

For CLI/MCP access, enable **Command line & AI tools** in GhostCopy settings.
`ghostcopy` is the CLI; `ghostcopy-desktop` opens the UI.

Use the tray's **Check for Updates** action to download and install a newer
Linux release. **Automatically check for updates** is enabled by default and
checks at startup and every 24 hours while running; it changes the tray action
to **Update available**. Downloads and installation require your confirmation.
The updater verifies the SHA-256 digest and version, stages the full GUI/CLI
bundle, waits for GhostCopy to quit, swaps the bundle and reopens it. No sudo.
It retains the previous bundle beside the installation as
`~/.local/lib/.ghostcopy-backup-<id>`; remove that backup after verifying the new
version. A replacement failure restores the previous bundle. Interrupted or
failed updates are recorded in `~/.cache/ghostcopy/last-update.json`; errors are
shown on the next app launch. The download cache is `~/.cache/ghostcopy/updates`
(or under XDG_CACHE_HOME).

Until the first release feed is published, a manual check explains that the feed
is unavailable. You can still quit the app and rerun the installer with a new
bundle. Uninstall with `python3 install_linux.py --uninstall`. It removes
recorded application files and the default installation's login entry, while
retaining credentials and account data. Custom `--prefix` installations need
`share` in XDG_DATA_DIRS and may require manual URI registration.

## Implemented paths

| Feature | Linux implementation |
| --- | --- |
| Spotlight, history, transformations, pinning | Shared Flutter UI with XWayland window management |
| Background clipboard reads | Bounded local file URI, PNG/JPEG, text and HTML reads; password-manager secret markers are skipped |
| Clipboard change tracking / Smart Receive | Native Wayland selection events without payload reads; GTK owner changes on X11; falls back to full reads if the counter is unavailable |
| Clipboard writes | Existing multi-format GTK/XWayland offers, bridged by KWin |
| Sync, targets, encryption | Shared services and Linux Secret Service storage |
| Global shortcut | XDG Global Shortcuts portal on Wayland; keybinder on X11 |
| System tray | Native Open, Settings, Game Mode and Quit menu |
| Notifications | Native icon and action button; clicks act while the app runs |
| Dolphin menu | Send with GhostCopy for multiple selected local files, preserving each filename |
| Browser sign-in | Desktop MIME handler and authenticated single-instance forwarding |
| Login startup | Quoted XDG autostart entry and hidden startup |
| Suspend/resume, lock/unlock | logind and Plasma ScreenSaver D-Bus signals |
| Temporary files | Native Wayland URI check before deleting old clipboard files |
| CLI and MCP | Compiled companion binary installed as `ghostcopy` |
| Updates | Automatic checks, confirmed install, checksum verification, GUI/CLI bundle replacement and rollback backup |

Clipboard priority matches the existing app: files, images, plain text, then
HTML when no plain-text alternative exists. A copied file selection captures
the first supported local file; use Dolphin's action to send multiple files.
The existing 10 MB attachment limit applies; Wayland streaming reads are bounded.

## Build from source

Use a Linux Flutter SDK satisfying pubspec.yaml. Windows cannot build this
target. Keep the SDK and build output on Linux's filesystem. The runner was
generated with Flutter 3.44.8; Linux validation used Flutter 3.44.0 / Dart 3.12.0
on Ubuntu 24.04 in a container.

Install the runtime prerequisites above, then:

```sh
sudo pacman -S --needed base-devel clang cmake ninja pkgconf wayland
bash tool/build_linux.sh
python3 tool/install_linux.py
```

The clipboard plugin needs a Rust toolchain when a prebuilt native library is
unavailable. The build script builds the GUI and CLI and targets Linux x86-64.

## Prepare a Linux release

Use a new stable version/build for every release. Build and package on Linux:

```sh
bash tool/build_linux.sh --build-name=1.0.9 --build-number=22
python3 tool/package_linux.py
```

The packager reads the compiled Flutter version, includes the updater and CLI,
and writes the tarball, checksum, and `latest.json` to `build/linux-package`.
It never publishes. Publish the archive under the exact versioned tag
`linux-v1.0.9+22`, then upload `latest.json` to the separate `linux-updates`
release. Upload the archive first so clients never see an unavailable payload.
The feed URL is:
`https://github.com/g1mliii/Ghostcopy/releases/download/linux-updates/latest.json`.
The updater accepts only this repository's versioned Linux asset URL. HTTPS and
the repository's release permissions establish feed authenticity; the checksum
detects corruption or a mismatched asset, and is not an independent signature.
Do not overwrite versioned archives. To roll back a faulty published release,
publish its corrected contents under a higher version/build.

Test upgrades with a normal user and a staged prefix before publishing. The
Python updater tests cover replacement, rollback, version ordering, size/digest
validation and hostile archives; they do not exercise a published release or
an actual Plasma restart. A source build outside the per-user installer does
not self-update. Package-manager installations need their own updater policy.

## Validation

- Linux release GUI and CLI compilation in an Ubuntu container.
- CLI help executes; GUI shared-library dependencies resolve in that container.
- Flutter analysis and focused shared-service regressions on Windows.
- Linux D-Bus tests: immediate portal replies, activation, cancellation, session
  cleanup, and suspend/lock signals.
- Native Wayland test server: selection counters, primary-selection isolation,
  offer cleanup, disconnect/unsupported fallback, and no payload reads or writes.
- Installer tests: ownership, uninstall bounds, and filenames containing spaces,
  quotes, newlines and shell metacharacters.

These checks do not exercise real KWin focus, Dolphin, notifications, the wallet,
browser sign-in, or cross-device sync in your session.

Run `bash test/linux/run_native_tests.sh` for the native monitor tests (requires
Wayland client/server development libraries and `wayland-scanner`). The opt-in
build-check workflow also has a Linux job; it compiles and packages without
publishing. The monitor uses the first advertised seat, matching the intended
single-seat desktop. Multi-seat sessions have not been validated.

## CachyOS acceptance checklist

Record `echo "$XDG_CURRENT_DESKTOP / $XDG_SESSION_TYPE"` with results.

1. Launch from the menu: Spotlight and one tray icon appear. Launch again: the
   existing instance opens. Close Spotlight: the app stays in the tray.
2. Check tray Open/Settings/Game Mode/Quit and the Game Mode checkmark.
3. Test the shortcut with a native Wayland app focused, then an XWayland app.
   Check focus and repeated show/hide. Configure a different shortcut in KDE.
4. Copy Unicode text with trailing newlines, images, HTML-only content, and a
   local file while hidden. Test native Wayland and XWayland producers. Paste
   received formats into other apps.
5. Send/receive with Windows/iOS, encrypted and unencrypted. Check that incoming
   clips do not repeat in a sync loop.
   With Smart Receive enabled and automatic sending disabled, copy locally,
   then receive from another device: the recent local copy should stay intact.
   Selecting text for middle-click paste must not count as a clipboard copy.
6. Receive while hidden: check notification icon, action button and copy action.
   Enable Game Mode and check that it suppresses notifications.
7. Send one and multiple files from Dolphin, including names with spaces.
   Check selected device targets, confirmation, and oversized-file refusal.
8. Complete browser sign-in with the app running and after quitting. Restart
   and verify session/encryption persistence with the wallet locked/unlocked.
9. Enable login startup, log out/in: Spotlight should stay hidden. Disable
   startup and confirm the app does not return at the next login.
10. Lock/unlock, suspend/resume and reconnect networking. Check sync recovery,
    multiple monitors, mixed DPI, pinning, and focus dismissal.
11. Enable CLI access and test `ghostcopy devices`, `ghostcopy send`, and MCP.
12. Exercise an old-to-new installed build update: decline first, then approve,
    verify automatic restart and GUI/CLI versions, and inspect the rollback copy.
    With access disabled, requests should be refused.

References: [Global Shortcuts portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html),
[wl-clipboard](https://github.com/bugaevc/wl-clipboard),
[Dolphin service menus](https://develop.kde.org/docs/apps/dolphin/service-menus/),
[Flutter Linux setup](https://docs.flutter.dev/platform-integration/linux/setup).
