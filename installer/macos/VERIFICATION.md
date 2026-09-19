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
