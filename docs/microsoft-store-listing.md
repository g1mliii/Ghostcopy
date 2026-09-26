# Microsoft Store listing - Windows

Everything Partner Center asks for, drafted against the code on 2026-09-25
rather than from memory. Where a line states what the app does, it was checked
in `lib/`; keep it that way when editing.

Reserved name: **GhostCopy**. Store ID `9NW0TTGMSF80`, listing URL
https://apps.microsoft.com/detail/9NW0TTGMSF80.

## Two ways this differs from the App Store draft

Both are easy to get wrong by adapting `docs/app-store-listing.md` line by
line.

**Other platforms can be named here.** Apple's guideline 2.3.10 bans it, which
is why the iOS listing never says Android and only mentions Windows in
passing. Microsoft has no equivalent rule, and for this app the cross-device
story *is* the product - so say Mac, iPhone and Android plainly.

**The publisher name is public and is currently a handle.** Partner Center
issued `g1mli` as the publisher display name, and that is what customers see
under the app title in the Store. It also has to match
`publisher_display_name` in `msix_config`, so changing it means changing both.
Decide before submitting; it is far more awkward to change once people have
installed.

## Product details

| Field | Value |
|---|---|
| Name | GhostCopy |
| Category | Productivity |
| Subcategory | Personal finance - no; use **Productivity > Other** unless a better fit appears in the picker |
| Price | Free |
| Markets | All, with the France note under "Encryption" below |
| Privacy policy URL | https://ghostcopy.app/privacy |
| Support contact | https://ghostcopy.app/faq (has a contact section) |
| Website | https://ghostcopy.app |
| Copyright | 2026 *legal name* - fill in; it is shown publicly |

## Properties page, field by field

### Category

**Productivity.** No subcategory applies; if the picker insists, take the
most generic option rather than inventing a fit. "Utilities & tools" is the
defensible alternative, but Productivity is where people look for this.

### Privacy policy

> Does this product access, collect, or transmit personal information?

**Yes.** Not a judgement call: the app handles email addresses, clip
contents, per-device identifiers and crash diagnostics. Answering yes makes
the privacy policy URL mandatory, which is https://ghostcopy.app/privacy.

### Support info

| Field | Value |
|---|---|
| Website | https://ghostcopy.app |
| Support contact info | https://ghostcopy.app/faq |
| Phone number | leave blank |
| Address lines, postal code, city, state, country | leave blank |

**Everything on this page is shown publicly on the listing.** The account is
an Individual one, so the address here would be a home address. Leave it
empty - it is optional, and a support URL is the better contact route
anyway.

### Display mode

Windows Mixed Reality. **Leave entirely unchecked**, including both boundary
options - ticking either declares this an immersive headset experience.

### Product declarations

Defaults are right for almost all of it. The ones with a real answer:

- Contains or displays ads: **No**
- Purchases outside the Microsoft commerce engine: **No**
- Broadcast/recording: not applicable, Games only
- **Tested for accessibility: do NOT tick.** It has not been tested, and
  `primary` on `surface` is 4.44:1 - under AA and still open in the todo.
  This one is a claim, not a formality.

The app needs an internet connection to do anything; if a declaration about
working offline is offered, leave it unticked.

### System requirements

**Leave every row blank.**

This is the field most likely to be filled in out of helpfulness and do
harm. A *Minimum* that a customer's hardware does not meet shows them a
warning before download and blocks them from rating or reviewing the app.
Nothing here is genuinely required:

- **Keyboard** - the hotkey is the main way in, but the tray icon opens the
  window with a mouse alone, so it is not required.
- **Mouse** - likewise, not required.
- **Camera** - checked in the code, not needed. Desktop *displays* the
  linking QR code; the phone scans it. `mobile_scanner` appears only in
  `mobile_welcome_screen.dart`.
- **Memory, DirectX, video memory, processor, graphics** - Flutter renders
  through ANGLE, but no floor has been measured, and guessing one only
  excludes people.
- Touch, NFC, Bluetooth LE, telephony, microphone, Xbox controller, Mixed
  Reality - none used.

If anything is declared at all, make it Keyboard as *Recommended*, which
carries no warning and no review block.

## Store listing page, field by field

### Description

Use the long description below. **Required**, and the only text field that is.

### What's new in this version

**Leave blank.** Partner Center says to for a first submission, and it means
it - anything here reads as an update note on a product nobody has yet.

### Product features (bulleted, up to 20)

> - Send what you copy to your phone with a global hotkey
> - Right-click any file in File Explorer and send it, without opening the app
> - Works with Mac, iPhone and Android as well as Windows
> - Optional end-to-end encryption with a passphrase only your own devices hold
> - Recent clipboard history on every device
> - Choose which devices receive each clip
> - Received clips can be copied to your clipboard automatically
> - Lives in the system tray and opens on a hotkey you choose
> - Game Mode holds notifications back while you are in a fullscreen app
> - Text and links up to 100 KB; images and files up to 10 MB
> - No ads, no analytics, no tracking

### Short description (270 recommended)

Shorter than the 500 the field allows - 270 is what actually displays.

> Copy on your PC and it is on your phone's clipboard a second later.
> GhostCopy syncs text, links, images and files between Windows, Mac, iPhone
> and Android, with a global hotkey, a File Explorer right-click, and optional
> end-to-end encryption.

### Keywords (7 max, 40 chars each, 21 words total)

```
clipboard sync
copy paste sync
send to phone
clipboard manager
share files between devices
clipboard history
cross device clipboard
```

Nineteen words, inside the 21-word ceiling. "GhostCopy" is not repeated - the
product name is indexed already.

### Developed by

**Worth thinking about rather than skipping.** This is a separate field from
the publisher display name, and it is shown publicly on the listing. The
publisher name is fixed to `g1mli` because the package identity depends on
it; this one is free text. If a proper name is wanted anywhere in the Store,
this is the field that can carry it today without touching the manifest.

### Copyright and trademark info

> (c) 2026 *legal name* - fill in; it is shown publicly

### Additional license terms

**Leave blank.** The Standard Application License Terms are unmodified.
`/terms` covers the hosted service and can be added here later if wanted.

### Fields to skip entirely

- **Short title, Voice title** - Xbox only
- **Trailers, closed captions, audio descriptions** - none
- **16:9 Super hero art** - only needed to put a trailer at the top of the
  listing, and there is no trailer
- **Xbox images** (branded key art, titled hero art, featured square) - not
  on Xbox

## Images

Generated by `tool/generate_store_images.py` into
`docs/microsoft-store-images/`, which is upload material rather than app
assets. Kept out of `generate_brand_assets.py` deliberately: that one owns
what ships inside the app and rasterises the master SVGs, which needs Cairo,
and Cairo does not load on Windows - where the submission is made. These are
compositions of an icon it already produced, so Pillow alone is enough.

| Slot | File | Needed? |
|---|---|---|
| 9:16 Poster art | `poster-720x1080.png`, `poster-1440x2160.png` | **Upload.** Main logo on Windows 10/11, and the package has nothing this shape |
| 1:1 Box art | `boxart-1080x1080.png`, `boxart-2160x2160.png` | Recommended |
| App tile icon 300/150/71 | `tile-*.png` | Optional - the package already carries these |

Store logos are optional in general: without them Partner Center falls back
to the tile images inside the package.

### Screenshots - at least one, and these cannot be generated

The only blocking asset left. Partner Center wants 1366x768 or larger; take
them at 1920x1080 on a clean desktop, signed in to the demo account so the
history matches the App Store captures. Four is the recommended minimum.

See the screenshot list further down - the Spotlight window over a real
desktop is the one that has to carry the listing.

## Short description (500)

Shown in search results and on the product tile, so it has to stand alone.

> Copy on your PC, send it, and it is on your phone's clipboard a second
> later. GhostCopy moves text, links, images and files between your Windows
> PC, Mac, iPhone and Android devices - with a global hotkey, a right-click in
> File Explorer, and optional end-to-end encryption with a passphrase only
> your own devices hold.

## Description

> GhostCopy moves what you copy between your computer and your phone.
>
> Press Ctrl+Shift+S anywhere in Windows and GhostCopy opens over whatever you
> are doing. Send what you copied, and it lands on your phone as a
> notification - tap it and the text is already on the clipboard. Right-click
> any file in File Explorer and choose "Send with GhostCopy" to send it
> without opening anything.
>
> Going the other way is just as short: send from your phone and it arrives on
> the PC, ready to paste.
>
> PRIVATE BY DESIGN
> - Set a passphrase and every clip, file and image is encrypted on your
>   device with AES-256-GCM before it leaves. We store ciphertext and cannot
>   read it.
> - The passphrase never leaves your devices. Adding a new one is a QR code
>   scanned from a device you already have.
> - No ads, no analytics, no tracking.
>
> BUILT FOR EVERY DAY
> - Lives in the system tray and stays out of the way. Opens on a hotkey you
>   choose.
> - Recent history on every device, so a clip you missed is still there.
> - Text and links up to 100 KB; images and files up to 10 MB.
> - Choose which devices receive each clip.
> - Received clips can be copied to your clipboard automatically.
> - Game Mode holds notifications back while you are in a fullscreen app.
> - Sign in with Apple, Google or email to keep your history across devices
>   and reinstalls.
>
> WORKS WITH YOUR OTHER DEVICES
> GhostCopy is also available for Mac, iPhone and Android, and syncing between
> them is the point - a clip from your PC reaches whichever of your devices
> you choose.

## Search terms (up to 7, 30 chars each)

```
clipboard sync
copy paste sync
send to phone
clipboard manager
share files between devices
clipboard history
cross device clipboard
```

The product name and category are indexed already, so "GhostCopy" is not
repeated here.

## What's new in this version

First release, so keep it plain:

> First release of GhostCopy for Windows.

## Screenshots (to take)

At least one is required; up to ten. Minimum 1366 x 768, PNG. Take them at
1920 x 1080 on a clean desktop with the demo account signed in - the same
account the App Store screenshots use, so history looks consistent across
stores.

1. The Spotlight window open over a normal desktop, with a clip in the
   composer and history below. This is the one that has to carry the app.
2. The history list showing a mix of text, a link and an image.
3. Device targeting - choosing which devices receive a clip.
4. The File Explorer right-click menu showing "Send with GhostCopy".
5. Settings, showing the encryption passphrase and launch-at-startup.

Do not capture the tray flyout on its own: it reads as a fragment without the
main window for context.

## Age rating

Answered through the IARC questionnaire, which Partner Center runs inline.
Expected result: the equivalent of **3+ / Everyone**.

Answer **No** to every content question - no violence, sexual content,
gambling, drugs, profanity, or in-app purchases. Two that need care because
the honest answer is not the obvious one:

- **Does the app let users interact or share content with other users?**
  **No.** Clips move only between devices signed in to the *same* account.
  There is no messaging, no sharing with other people, and nothing another
  user can see.
- **Does the app share the user's location?** **No.** The iOS build carries a
  location purpose string for a dependency, but nothing in the app requests
  or transmits location.

## Product declarations

- Testing on all device families: it is a desktop app; declare Windows
  Desktop only.
- The app **does** access the internet - required, and the privacy policy URL
  above is therefore mandatory rather than optional.
- No in-app purchases, no ads, no commerce engine.
- Accessibility: do **not** tick "tested for accessibility" - it has not
  been, and the `primary`-on-`surface` contrast issue at 4.44:1 is still
  open in `tasks/todo.md`.

## Privacy: what the app collects

The Store does not ask for Apple's per-type table, but the privacy policy has
to match reality and a reviewer may check. This is the same set the App Store
answers declare, restated for Windows:

| Data | Why |
|---|---|
| Email address | Account sign-in and upgrade |
| Clip content - text, images, files | The product. Encrypted on the device first when a passphrase is set |
| Account and device identifiers | Routing a clip to the right devices |
| Crash and error diagnostics | Sentry. No IP, no user id, no screenshots; clip text stripped on the device before sending |

Not collected: location, contacts, browsing history, health, financial data,
usage analytics.

**Sentry must be declared**, as it is on the App Store. It is easy to forget
because it is not a visible feature.

## Encryption

The app implements AES-256-GCM and PBKDF2-HMAC-SHA256 itself, in Dart, on top
of the OS's HTTPS. Microsoft does not run Apple's export questionnaire, but
the underlying law is the same, so two things still apply:

- France requires a declaration to ANSSI for software implementing its own
  encryption. The App Store draft excludes France for the first release for
  this reason; decide whether the Windows listing does the same, and keep the
  two consistent.
- Whether a US self-classification report is needed is a legal question.
  Confirm rather than assume - the answer does not change per store.

## Notes for certification

Certification is automated plus a human pass, and the app's main feature needs
a second device, so say so:

> GhostCopy syncs the clipboard between a user's own devices, so its main
> feature needs a second device signed in to the same account.
>
> To test on one machine: press Ctrl+Shift+S, paste text into the composer and
> send. It appears in the history below. Right-clicking a file in File
> Explorer and choosing "Send with GhostCopy" sends it the same way.
>
> A demo account is provided below. Encryption is optional and off by default.
> Account deletion is in the app under Settings.
>
> The app runs in the system tray and has no window on launch by design - open
> it with Ctrl+Shift+S or from the tray icon.

That last paragraph matters: a tester who launches the app and sees no window
may report it as failing to start.

## Demo account

The same account as the App Store submission (see
`docs/app-store-listing.md`), signed in on a second device so history and
device targeting have something to show. Leave it without a passphrase so no
one is prompted for one.

## Packages

Upload **`build\windows\x64\runner\Release\ghostcopy.msix`** - the one
`build-store.ps1` writes. Not the signed copy used for sideloading: the Store
signs packages itself and rejects one that already carries a signature.

**Device families:** tick Windows 10/11 Desktop only. It is the sole family
the manifest declares (`Windows.Desktop`, min 10.0.17763, which is Flutter's
floor rather than a choice). Ticking a family the package does not target
fails validation rather than widening reach.

### The version must end in .0

`msix_version` is Major.Minor.**Build**.**Revision**, and the Store rejects any
package whose revision is not zero:

> Apps are not allowed to have a Version with a revision number other than
> zero specified in the app manifest.

So the shared build number goes in the *third* part. Build 9 is **1.0.9.0**,
not 1.0.0.9. A version can never be reused - not even by a submission that
failed certification - so raise it before rebuilding after a rejection.

### The runFullTrust warning is expected

> The following restricted capabilities require approval before you can use
> them in your app: runFullTrust.

A **warning, not an error**, and unavoidable: every packaged Win32 desktop app
declares `runFullTrust`, because that is what `Windows.FullTrustApplication`
means. msix adds it automatically. Submission proceeds with it.

It is reviewed rather than blocked, so say plainly in the notes to
certification what the full-trust access is for: a global hotkey, the system
tray, clipboard read/write, and a File Explorer context-menu handler - none
of which the sandboxed app model can do.

### Arm64

The package is x64 only. Partner Center's Arm warning is about **AArch32**
(ARM32), which this does not target at all, so it does not apply. x64 runs on
Windows on Arm under emulation, and this app idles at near-zero CPU, so the
overhead is irrelevant. Flutter cannot cross-compile x64 to Arm64 - it needs
an Arm64 Windows machine - so a native build is a later question, worth
revisiting only if Store analytics show the demand.

## Submission options

### Publishing hold

Choose **"Don't publish this submission until I select Publish now."**

Certification can take anywhere from hours to days, and the default would put
the app live the moment it passes - possibly overnight, with nobody watching.
Holding it costs nothing, and buys a look at the rendered listing, a check
that the download page and website agree with it, and control over the hour it
appears. It can be released with one click afterwards.

### runFullTrust justification

The field asks for as much detail as possible, so it gets it. This is a
restricted capability, and a thin answer invites a follow-up:

> GhostCopy is a Win32 desktop application packaged with MSIX
> (Windows.FullTrustApplication). Full trust is required because every core
> function of the app is unavailable to a sandboxed application:
>
> - A system-wide global hotkey (Ctrl+Shift+S by default), so the user can
>   summon the clipboard window from any application without leaving what
>   they are doing.
> - Reading and writing the Windows clipboard, including images and files.
>   This is the entire purpose of the product.
> - A system tray icon with a context menu; the app runs in the background
>   between uses.
> - A File Explorer context menu entry ("Send with GhostCopy"), implemented
>   as an IExplorerCommand handler and declared in the manifest under
>   desktop4:FileExplorerContextMenus.
> - Launching at login through the declared uap5:StartupTask.
>
> Full trust is not used to read other applications' data, change system
> settings, or install drivers or services. Network access is limited to the
> app's own backend (Supabase) and Cloudflare R2 for file storage.

### Administrator consent - leave blank

That page is for products integrating with Microsoft Entra Identity and
calling APIs needing admin consent. GhostCopy authenticates through Supabase
with Apple, Google or email, and touches no Microsoft identity service. No
Client ID exists to enter.

### Submission notification audience

Leave as the default.

## Additional testing info

Fill this in - it is not optional in practice. A tester who cannot work out
how to exercise the app fails it.

### Notes for certification

> GhostCopy syncs the clipboard between a user's own devices.
>
> NO SIGN-IN IS NEEDED TO TEST. The app creates a guest account on first
> launch, so everything below works immediately.
>
> The window opens on launch. Once closed it keeps running in the system
> tray, which is where a background clipboard utility belongs; reopen it with
> Ctrl+Shift+S or by clicking the tray icon.
>
> To exercise the app on a single machine:
> 1. Type or paste text into the box at the top and press Send.
> 2. It appears in the history list below.
> 3. Right-click any file in File Explorer and choose "Send with GhostCopy".
>    A Windows notification confirms it was sent.
>
> The headline feature - a clip arriving on a phone or Mac - needs a second
> device signed in to the same account, which we appreciate may not be
> available. Optional credentials for an account with existing history are in
> the Credentials section; signing in with them shows history and device
> targeting populated.
>
> Encryption is optional and off by default (Settings > Encryption). Account
> deletion is in Settings.

### Credentials

Optional here, unlike the App Store, because Windows has a guest path and iOS
does not. Provide the same demo account anyway: it costs nothing and it is
the difference between a tester seeing an empty app and a populated one.

Credentials go in the Credentials fields, never in the description - the page
says so explicitly.

## Before submitting

- [ ] `identity_name`, `publisher` and `publisher_display_name` in
      `msix_config` match Partner Center exactly - the upload is rejected
      otherwise
- [ ] `msix_version` is higher than the last submission, fourth part `0`
- [ ] Built with `installer/windows/build-store.ps1`, so the symbols went to
      Sentry before the package was made
- [ ] The decision on the publisher display name has been made
