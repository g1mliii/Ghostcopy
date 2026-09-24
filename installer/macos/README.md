# macOS Developer ID installer

Run from a logged-in macOS desktop with Flutter, CocoaPods, Rust, Xcode, and
Python 3 installed. Xcode must be signed into team `R9TKT8U45R`; its Keychain
must contain the Developer ID Application certificate and private key.
Automatic export also needs a Developer ID provisioning profile for
`com.ghostcopy.ghostcopy` that authorizes the existing Keychain access group.
Xcode downloads/creates this with `-allowProvisioningUpdates` when permitted.

```bash
installer/macos/build-release.sh ghostcopy
# Optional Flutter flags, for example:
installer/macos/build-release.sh ghostcopy --build-name=1.0.0 --build-number=2
```

`ghostcopy` is the local notarytool Keychain profile name, not a password.
Other machines must store their own credentials with `xcrun notarytool
store-credentials`. No credentials or provisioning profiles belong in Git.

The script generates Flutter configuration, archives Release, exports using
Xcode's `developer-id` method, validates the exported signing/profile pairing,
notarizes and staples the app, then creates, signs, notarizes and staples the
DMG. Outputs are kept in a timestamped directory under `build/installer/`.
Finder may request automation access to save the disk image's icon layout.
The image contains the app and an Applications shortcut, with a generated
background explaining the drag-to-install operation.

The mounted volume and the `.dmg` file use the GhostCopy app icon. macOS
stores a downloaded file's custom Finder icon as local metadata, so a browser
or file service may show the generic disk-image icon for the file before it is
opened. The mounted installer window is the reliable branded surface and
always contains the GhostCopy app icon.

## Sparkle updates

The step-by-step release runbook - version numbering, publishing, local
update testing and rollback - is [`docs/macos-releases.md`](../../docs/macos-releases.md).
This section covers how the pieces are put together.

The release app embeds Sparkle 2.10.0 and checks the signed appcast at
`https://github.com/g1mliii/Ghostcopy/releases/download/macos-updates/appcast.xml`.
The menu bar offers **Check for Updates…** and a preference for scheduled
checks. Scheduled notices are kept gentle for this tray-only app; they do not
take focus away from the current application. Update archives and appcasts are
verified with Sparkle Ed25519 signatures as well as Apple's Developer ID and
notarization checks.

The updater key is generated once in the login Keychain under the
`com.ghostcopy.ghostcopy` account. Keep that private key in the Keychain and
never commit or print it. The public key is in `macos/Runner/Info.plist`.

To prepare a candidate after a clean build:

```bash
installer/macos/build-release.sh ghostcopy --build-name=1.0.0 --build-number=2
```

That command refuses an unresolved signing/profile setup, validates the
notarized DMG, records the source commit, and generates a signed local
appcast. Review the candidate and release notes, then publish explicitly:

```bash
installer/macos/publish-update.sh build/installer/YYYYMMDD-HHMMSS \
  "<full pushed commit SHA>"
```

The release body is not passed here. It is extracted from the appcast, which
is the copy that was signed, so the GitHub release and the update dialog cannot
say different things.

Publishing creates a versioned draft GitHub release first, then updates the
fixed `macos-updates` feed release and downloads the live feed again to verify
that it matches the signed local feed. It will refuse a dirty or mismatched
source commit. Do not publish a build number already present in the feed.

## Why archive/export matters

Do not hand re-sign a Flutter build with `Runner/Release.entitlements`.
`codesign` does not expand `$(AppIdentifierPrefix)`. Do not remove the
embedded provisioning profile or the Keychain entitlement to make launch work:
restricted entitlements must be authorized by the distribution profile, and
changing the Keychain group can orphan existing encryption passphrases.
Xcode's export resolves these together. The source Release signing identity
can remain Apple Development: export performs the Developer ID distribution
signing independently.

The build script keeps Rust host build-dependency debug information as a
workaround for macOS 27 rejecting some stripped proc-macro dylibs with
`mis-aligned LINKEDIT string pool` (often surfaced as Rust E0463). See
[the Rust compiler issue](https://github.com/rust-lang/rust/issues/157750).
This is scoped to the packaging process; it does not change the global Rust
installation or the iOS project.

## Required installed-app verification

A valid signature and accepted notarization are not proof that an app launches.
For every candidate:

1. Quit any running GhostCopy copy.
2. Mount the final DMG and check the icon layout and Applications shortcut.
3. Drag GhostCopy to Applications. Preserve any existing installed app if needed.
4. Run `xcrun swift installer/macos/smoke-test.swift /Applications/GhostCopy.app`.
   This uses LaunchServices, verifies the exact bundle path, and checks the
   process stays alive for 12 seconds. It leaves the app open for inspection.
5. Check the tray and Option+Space, then test clipboard sync and encrypted
   history with an existing passphrase. The smoke test does not establish
   those functional behaviors.

For an isolated install check without replacing an existing app, use a fresh
subdirectory in `~/Applications` and pass its exact `.app` path to the smoke
test. That still uses the same login Keychain and app preferences.

Useful standalone commands:

```bash
python3 installer/macos/verify-app.py /path/to/export/ghostcopy.app
installer/macos/create-dmg.sh /path/to/export/ghostcopy.app /path/to/GhostCopy.dmg
xcrun stapler validate /path/to/GhostCopy.dmg
spctl --assess --type execute --verbose=2 /Applications/GhostCopy.app
```

`create-dmg.sh` only makes the layout. It does not sign/notarize the disk image
or prove the supplied app is a release export; use `build-release.sh` for a
complete candidate.

## Branch scope

This packaging work starts at `ios/bring-up` commit `469d1d8` on
`codex/macos-installer`. Keep iOS bring-up fixes on their own branch; merge or
cherry-pick them here when needed. Packaging fixes belong here first.
