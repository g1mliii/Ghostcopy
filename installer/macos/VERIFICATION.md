# Local installer verification — 2026-09-19

Source: `ios/bring-up` at `469d1d8`, packaging on `codex/macos-installer`.
Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a).

- Xcode Release archive and automatic Developer ID export succeeded.
- Export validation passed: resolved application/team identifiers, unchanged
  `R9TKT8U45R.com.ghostcopy.ghostcopy` Keychain group, a non-expired Developer ID
  profile authorizing all devices, and a signing certificate included in that
  profile. Hardened Runtime is enabled; the debug entitlement is absent.
- The executable contains both `x86_64` and `arm64` slices. Runtime testing
  here used Apple Silicon; Intel runtime behavior was not tested.
- The validator rejected the prior `GhostCopy-update.zip` from the user's
  Desktop because it contained an unexpanded Xcode entitlement variable.
- App notarization: Accepted, `02451934-19ed-43ce-bff2-9653d400d3ee`.
- DMG notarization: Accepted, `9baf70d1-cff8-4ee5-acfe-1af9570a50b6`.
- App and DMG staple validation succeeded. Gatekeeper assessed the exported
  and installed app as `accepted`, source `Notarized Developer ID`.
- The compressed image's Finder window was inspected: app icon on the left,
  Applications shortcut on the right, arrow and clear instructions, no overlap.
  The user confirmed that the layout worked much better.
- Copied the app out of the final mounted DMG into `/Applications/GhostCopy.app`,
  preserving the previous app under `build/installer/previous-installed/`.
  The LaunchServices smoke test verified that exact path and that PID 93763
  remained alive for 12 seconds. It was still running more than a minute later.
- Shell syntax, plist parsing, Swift type-checking, and Git whitespace checks
  passed. No Flutter application source changed, so Flutter unit tests were
  not rerun; the release archive compiled the application and native plugins.
- Sparkle 2.10.0 resolved through Swift Package Manager and was embedded in a
  Release archive/export. The updater bridge passes four focused Flutter tests
  and `flutter analyze` reports no issues. Its feed URL and Ed25519 public key
  are checked by the release validator before a candidate can be prepared.
- The new DMG builder applies the GhostCopy icon to the local `.dmg` file and
  keeps the app icon in the mounted installer window. Some download services
  discard Finder's local file-icon metadata, so the branded mounted window is
  the portable guarantee.

The UI automation tool timed out when inspecting the running tray application.
Clipboard sync, existing-passphrase decryption, and Intel launch remain manual
functional checks; notarization and the process smoke test do not establish them.

The delivery copy is `~/Desktop/ghostcopy-dist/GhostCopy-fixed.dmg`; the old
Desktop artifacts were preserved. No release was published to GitHub or the site.

## Update install verification — 2026-09-22

Sparkle build 2 -> build 3 upgrade, exercised against a local feed; nothing was
published to GitHub.

- Candidate: `build/installer/20260919-200239`, source commit `59cf81e`, clean
  tree. App and DMG both notarized (DMG submission `8a5d6685-1e2d-4aca-a407-5d2121e0cb02`,
  Accepted) and stapled; `verify-app.py --require-updater` passed.
- `generate_appcast` re-signed the feed with a `http://localhost:8765/` prefix;
  `SURequireSignedFeed` is on and Sparkle accepted the signed local feed.
- `sparkle --probe` from the installed build 2 reported an update available.
- The full non-interactive run downloaded 24,161,234 bytes, verified, extracted
  and installed. `/Applications/GhostCopy.app` is now 1.0.0 build 3, staple
  validates, and Gatekeeper reports `accepted / Notarized Developer ID`.
- The LaunchServices smoke test passed on the updated copy (PID 44320).
- No feed override was left behind: `--feed-url` is per invocation, and the
  installed app's `SUFeedURL` is still the GitHub `macos-updates` feed.
- The candidate's `appcast.xml` was restored to the GitHub download prefix and
  re-verified afterwards, so it remains publishable as `macos-v1.0.0-3`.

Not covered by this run: the Sparkle update UI itself (gentle reminder, the
menu bar "Update available…" item, and the dialog's Install button), which
still needs one manual pass.

## Update UI verification — 2026-09-22

The same build 2 -> build 3 upgrade, this time through the Sparkle UI rather
than the CLI, against the local feed.

- Tray **Check for Updates…** against the real `SUFeedURL` reported "Update
  Error! An error occurred when retrieving update information." Expected: the
  `macos-updates` feed 404s because nothing has been published yet. It does
  confirm the menu item is wired and that Sparkle's UI shows and takes focus
  from this `LSUIElement` agent app.
- Repointed at the local feed, the update dialog appeared with the embedded
  release notes rendered, and the user installed from it. The feed log shows
  the appcast fetch followed by the DMG download.
- Sparkle quit the app, installed, and **relaunched it automatically**: the
  process came back under a new PID and `/Applications/GhostCopy.app` is build
  3 with a valid staple. For a tray app this reads as the menu bar icon briefly
  disappearing and returning.
- An automatic scheduled check also fired on launch, before any manual check.

Found while setting this up: `prepare-update.sh` produced an appcast with no
release notes at all, so the first published update would have shown a blank
dialog. Notes now have to be an HTML fragment, are embedded into the signed
appcast at prepare time, and `publish-update.sh` refuses a candidate without
them.

Also noted, not fixed: a stale `~/Library/Containers/com.ghostcopy.ghostcopy`
sandbox container from before the sandbox was dropped still exists on this
machine. It makes the plain `defaults` command target the container instead of
`~/Library/Preferences/com.ghostcopy.ghostcopy.plist`, which is where the
unsandboxed app actually reads and writes. Only affects machines that ran a
sandboxed build.
