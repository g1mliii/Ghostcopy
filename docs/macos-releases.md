# Shipping a macOS update

How a GhostCopy macOS build gets from a commit to an installed app on someone
else's Mac. The scripts live in [`installer/macos/`](../installer/macos/); that
directory's [README](../installer/macos/README.md) explains the signing and
packaging decisions behind them. This file is the runbook.

## What a release actually is

Two GitHub releases, with different jobs:

| Release | Tag | Contents | Changes per release? |
|---|---|---|---|
| Installer | `macos-v<version>-<build>` | `GhostCopy-<version>-<build>.dmg` | New tag each time |
| Update feed | `macos-updates` | `appcast.xml` | Same tag, file replaced |

The app's `SUFeedURL` points at the **fixed** `macos-updates` tag, so the feed
URL compiled into every shipped build never changes. The feed's single item
points at that release's own versioned tag, so an installer binary is uploaded
once and never overwritten. Windows or Android releases can come and go on
`latest` without touching either.

Sparkle only ever compares `CFBundleVersion` — the **build number**. The
marketing version (`CFBundleShortVersionString`) is what people see. Both are
passed on the command line; `pubspec.yaml` stays at `1.0.0+1` and is not the
source of truth for a release.

## One-time setup on a release machine

- Xcode signed into team `R9TKT8U45R`, with the Developer ID Application
  certificate **and its private key** in the login Keychain.
- A notarytool Keychain profile. Ours is named `ghostcopy`:
  `xcrun notarytool store-credentials ghostcopy` (App Store Connect API key or
  an app-specific password). The name is not a secret; the credential is.
- The Sparkle EdDSA private key in the login Keychain under the account
  `com.ghostcopy.ghostcopy`, created once with `generate_keys`. **This key is
  the release.** Lose it and every installed copy stops accepting updates,
  because the public half is compiled into `macos/Runner/Info.plist` and cannot
  be changed retroactively. Back it up somewhere a password manager would live,
  never in Git and never printed into a terminal transcript.
- `gh` authenticated against `g1mliii/Ghostcopy` with release write access.
- Rust, CocoaPods, Python 3, Flutter.

## The runbook

**1. Pick the build number.** It must be strictly greater than the one in the
live feed. Check what is published:

```bash
curl -sL https://github.com/g1mliii/Ghostcopy/releases/download/macos-updates/appcast.xml | grep sparkle:version
```

**2. Build, sign, notarize, package.** From a clean checkout of the commit you
intend to ship:

```bash
installer/macos/build-release.sh ghostcopy --build-name=1.0.1 --build-number=4
```

One command does the whole candidate: Flutter config, Release archive,
Developer ID export, export validation, app notarization and stapling,
Gatekeeper assessment, DMG layout, DMG signing, DMG notarization and stapling,
then `prepare-update.sh` to produce the signed appcast. Everything lands in
`build/installer/YYYYMMDD-HHMMSS/`, including `source-commit.txt` and
`source-dirty.txt` recording exactly what was built.

It takes roughly 10–20 minutes, most of it notarization waiting on Apple.

**3. Verify the candidate by hand.** Signature and notarization prove nothing
about whether the app runs. Mount `GhostCopy.dmg`, drag it to Applications, and:

```bash
xcrun swift installer/macos/smoke-test.swift /Applications/GhostCopy.app
```

Then use it: tray menu, Option+Space, send a clip, and — most importantly —
confirm encrypted history still decrypts with the existing passphrase. A
signing or entitlement change that orphans the Keychain group passes every
automated check and still loses everyone's clips.

**4. Push the commit.** The publish step refuses a commit that GitHub has never
seen, and refuses a candidate whose recorded commit does not match.

**5. Write release notes.** A plain Markdown file; it becomes the GitHub release
body and is what Sparkle shows in the update dialog.

**6. Publish.**

```bash
installer/macos/publish-update.sh build/installer/YYYYMMDD-HHMMSS \
  "$(git rev-parse HEAD)" release-notes.md
```

This creates the versioned release as a **draft** with the DMG attached, flips
it public but not `latest`, then replaces `appcast.xml` on the `macos-updates`
release — binary first, feed second, so the feed never advertises a download
that does not exist yet. It finishes by re-downloading the live feed and
`cmp`-ing it against the local signed one.

**7. Confirm a real client sees it.** On a Mac running the previous build, use
**Check for Updates…** from the tray menu and let it install.

## What the scripts refuse, and why

| Refusal | Cause |
|---|---|
| `Unexpanded Xcode variable in signed entitlements` | Hand re-signed instead of archive/export |
| `Keychain group changed` | Entitlement drift that would orphan saved passphrases |
| `Missing profile authorizing Keychain access` | Export dropped `embedded.provisionprofile`; app will not launch |
| `Increase --build-number beyond the published macOS build` | Build number is not newer than the live feed |
| `Cannot check published version: HTTP <n>` | Feed unreachable — refuses to guess rather than ship a downgrade |
| `Already prepared` | `updates/` exists; delete it or build fresh rather than re-sign in place |
| `Publish only a candidate built from the supplied clean commit` | Working tree was dirty, or the candidate predates the commit |
| `Eject the mounted GhostCopy disk image` | A stale `/Volumes/GhostCopy` would have its Finder window edited instead |

## Testing an update without publishing

Point a test copy at a local feed. Nothing reaches GitHub.

```bash
# 1. Serve the prepared update directory
cd build/installer/YYYYMMDD-HHMMSS/updates
python3 -m http.server 8765 &

# 2. Regenerate the appcast with local download URLs
bin="$(installer/macos/sparkle-tools.sh)"
rm -f appcast.xml
"$bin/generate_appcast" --account com.ghostcopy.ghostcopy --maximum-deltas 0 \
    --download-url-prefix "http://localhost:8765/" .

# 3. Override the feed for the installed app only
defaults write com.ghostcopy.ghostcopy SUFeedURL "http://localhost:8765/appcast.xml"
```

Launch the older installed build and use **Check for Updates…**. Sparkle logs
the deprecation warning about a defaults-set feed URL; for testing it is
expected. `SURequireSignedFeed` is on, so the local appcast still has to be
EdDSA-signed — `generate_appcast` does that from the Keychain key.

Afterwards, always:

```bash
defaults delete com.ghostcopy.ghostcopy SUFeedURL
```

Leave that key set and the app keeps checking a dead localhost feed forever,
silently, which looks exactly like "updates are broken".

## If a bad build ships

There is no unpublish. Sparkle clients that already downloaded it are gone.
The feed carries a single item, so removing it only stops new clients from
updating; it does not roll anyone back.

The fix is always forward: build the corrected app with a **higher** build
number and publish it. If the bad release must stop spreading immediately,
delete `appcast.xml` from the `macos-updates` release first — the versioned
installer release can stay up for people who already have the link.

## Invariants

- Never change `SUPublicEDKey` or `SUFeedURL` in a shipped build.
- Never change `keychain-access-groups`. `verify-app.py` pins it to
  `R9TKT8U45R.com.ghostcopy.ghostcopy` precisely because a change here silently
  orphans every saved encryption passphrase.
- Never reuse or decrement a build number.
- Never overwrite an already-published installer asset. New build, new tag.
- Never publish from a dirty tree; the scripts check, but the habit matters more.
