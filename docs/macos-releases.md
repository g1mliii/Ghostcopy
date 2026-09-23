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

## What a user actually experiences

Nothing installs by itself. `SUAutomaticallyUpdate` is `false`, so every
update is a choice, every time.

`SUEnableAutomaticChecks` is `true` in `Info.plist`, which both turns scheduled
checks on and suppresses Sparkle's usual first-launch "check automatically?"
prompt. The app checks on Sparkle's normal schedule while it is running.

When a **scheduled** check finds an update, the user is not interrupted.
`AppUpdater` declares `supportsGentleScheduledUpdateReminders` and returns
`false` from `standardUserDriverShouldHandleShowingScheduledUpdate`, so no
window appears and nothing takes focus. Instead a dot appears next to the menu
bar icon and the tray item changes from **Check for Updates…** to **Update
available…**. It waits there until the user opens the menu.

When the user picks either menu item, they get Sparkle's normal dialog with the
release notes and an install button. Choosing to install quits the app,
installs, and **relaunches it automatically** - for a tray app that reads as
the menu bar icon disappearing for a few seconds and coming back. There is no
"update installed, please reopen" prompt, because the relaunch is the
acknowledgement.

That gentleness is a deliberate tradeoff and worth revisiting with real users:
a dot in the menu bar is easy to never notice, and someone who never opens the
tray menu will never update.

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

**5. Write release notes.** An **HTML fragment** - no `<!DOCTYPE>`, no `<body>`,
just the markup:

```html
<h2>GhostCopy 1.0.1</h2>
<p>What changed:</p>
<ul><li>…</li></ul>
```

The format is not a preference. `generate_appcast` embeds a fragment directly
into the signed appcast, which is what the update dialog renders. A Markdown
file or a full HTML document becomes a `sparkle:releaseNotesLink` instead,
pointing at a URL nothing in this pipeline uploads, so the dialog would fail to
load its own notes. Pass it to the build so it is embedded and signed:

```bash
RELEASE_NOTES=release-notes.html \
    installer/macos/build-release.sh ghostcopy --build-name=1.0.1 --build-number=4
```

Notes are embedded at prepare time, so they cannot be added at publish time.
`publish-update.sh` refuses a candidate whose dialog would be blank, and takes
no notes argument: it publishes the text out of the signed appcast. This step
used to accept a second notes file, and the example here passed a .md while the
appcast had been built from an .html - two files saying the same thing, with
nothing checking they agreed.

**6. Publish.**

```bash
installer/macos/publish-update.sh build/installer/YYYYMMDD-HHMMSS \
  "$(git rev-parse HEAD)"
```

This creates the versioned release as a **draft** with the DMG attached, flips
it public but not `latest`, then replaces `appcast.xml` on the `macos-updates`
release — binary first, feed second, so the feed never advertises a download
that does not exist yet. It finishes by re-downloading the live feed and
`cmp`-ing it against the local signed one.

**7. Confirm a real client sees it.** On a Mac running the previous build, use
**Check for Updates…** from the tray menu and let it install.

**8. Point the website at the new DMG.** The download page's button goes to
`/download/macos`, a redirect in `website/_redirects`. Release assets are
versioned and never `latest`, so GitHub has no stable URL for the newest DMG -
bump the tag and filename on that line and merge it to `main`, which deploys
the site. Forgetting costs little: whoever downloads the older DMG is offered
this update the first time the app checks.

## What the scripts refuse, and why

| Refusal | Cause |
|---|---|
| `Unexpanded Xcode variable in signed entitlements` | Hand re-signed instead of archive/export |
| `Keychain group changed` | Entitlement drift that would orphan saved passphrases |
| `Missing profile authorizing Keychain access` | Export dropped `embedded.provisionprofile`; app will not launch |
| `The Sparkle signing key does not match the one embedded in the app` | The Keychain key would sign an update every installed copy rejects |
| `Increase --build-number beyond the published macOS build` | Build number is not newer than the live feed |
| `Cannot check published version: HTTP <n>` | Feed unreachable — refuses to guess rather than ship a downgrade |
| `Already prepared` | `updates/` exists; delete it or build fresh rather than re-sign in place |
| `Publish only a candidate built from the supplied clean commit` | Working tree was dirty, or the candidate predates the commit |
| `Display name is not GhostCopy` | `CFBundleDisplayName` lost, so the app would introduce itself as "ghostcopy" |
| `Release notes must be an HTML fragment` | A DOCTYPE or `<body>` would make the notes a link instead of embedded text |
| `Release notes became a link` | Same cause; the dialog would try to load a URL that is never uploaded |
| `No release notes are embedded in the appcast` | Publishing would ship an update whose dialog is blank |
| `Eject the mounted GhostCopy disk image` | A stale `/Volumes/GhostCopy` would have its Finder window edited instead |

## Testing an update without publishing

Point a test copy at a local feed. Nothing reaches GitHub.

```bash
# From the repo root, against a directory build-release.sh already prepared.
release=build/installer/YYYYMMDD-HHMMSS
bin="$(installer/macos/sparkle-tools.sh)"

# 1. Re-sign the appcast with local download URLs
rm -f "$release/updates/appcast.xml"
"$bin/generate_appcast" --account com.ghostcopy.ghostcopy --maximum-deltas 0 \
    --download-url-prefix "http://localhost:8765/" "$release/updates"

# 2. Serve it
python3 -m http.server 8765 --directory "$release/updates" &

# 3. Override the feed for the installed app only
defaults write com.ghostcopy.ghostcopy SUFeedURL "http://localhost:8765/appcast.xml"
```

Launch the older installed build and use **Check for Updates…**.

### Non-interactively

Sparkle ships a CLI that drives the same updater without any UI, which is the
fastest way to prove the feed, the signature and the install all work. Build it
once from the package checkout the macOS project already resolved:

```bash
xcodebuild -project build/macos/SourcePackages/checkouts/Sparkle/Sparkle.xcodeproj \
    -scheme sparkle-cli -configuration Release \
    -derivedDataPath build/installer/sparkle-cli-build CODE_SIGNING_ALLOWED=NO build
cli=build/installer/sparkle-cli-build/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle
```

Then, with the local server running and the older build in `/Applications`:

```bash
# Is an update visible? Exit status 0 means yes.
"$cli" /Applications/GhostCopy.app --probe \
    --feed-url http://localhost:8765/appcast.xml --user-agent-name GhostCopyReleaseTest

# Actually download, verify and install it.
"$cli" /Applications/GhostCopy.app --check-immediately \
    --feed-url http://localhost:8765/appcast.xml --user-agent-name GhostCopyReleaseTest --verbose
```

`--probe` cannot be combined with `--check-immediately`; run them separately.
`--feed-url` is passed per invocation and does not persist, so this route needs
no `defaults delete` afterwards. Confirm the result rather than trusting the
exit status:

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/GhostCopy.app/Contents/Info.plist
xcrun stapler validate /Applications/GhostCopy.app
xcrun swift installer/macos/smoke-test.swift /Applications/GhostCopy.app
```

Remember to regenerate the appcast with the real GitHub prefix (or rerun
`prepare-update.sh`) before publishing, otherwise the published feed points at
a localhost URL. Sparkle logs
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
