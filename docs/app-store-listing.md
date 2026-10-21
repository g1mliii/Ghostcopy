# App Store listing - iOS

Everything App Store Connect asks for, drafted against the code on
2026-09-22 rather than from memory. Where a line states what the app does, it
was checked in `lib/`; keep it that way when editing - App Review compares the
listing and the privacy answers with the running app.

Metadata rule worth knowing before editing: App Review rejects listings that
name other mobile platforms (guideline 2.3.10), so nothing here mentions
Android. Windows is left out until it ships.

## App information

| Field | Value |
|---|---|
| Name | GhostCopy |
| Subtitle (30) | Clipboard sync across devices |
| Primary category | Utilities |
| Secondary category | Productivity |
| Price | Free |
| Privacy policy URL | https://ghostcopy.app/privacy |
| Support URL | https://ghostcopy.app/faq (has a contact section) |
| Account deletion URL (Google Play) | https://ghostcopy.app/delete-account |
| Marketing URL | https://ghostcopy.app |
| Licence agreement | Apple's standard EULA. `/terms` covers the hosted service and can be added as a custom EULA later if wanted |
| Copyright | 2026 *legal name or company* - fill in; it is shown publicly |

## Promotional text (170)

> Copy on your Mac, tap the notification on your iPhone, and it is on your
> clipboard. End-to-end encrypted with a passphrase only your devices hold.

## Keywords (100)

```
clipboard,copy,paste,sync,transfer,send,share,text,files,encrypted,mac,desktop,notes,link,pc
```

No spaces after commas - they count against the limit. The app name and
category are indexed already, so they are not repeated. Avoid "Universal
Clipboard" and "Handoff": they are Apple's feature names.

## Description (4000)

> GhostCopy moves what you copy between your computer and your phone.
>
> Copy something on your Mac, press Option+Space, send it - and a notification
> lands on your iPhone. Tap it and the text is already on your clipboard. Files
> and images open straight into the share sheet.
>
> Going the other way is just as short: paste into GhostCopy, pick where it
> should go, and send. Or share from any app - photos, files, links - and it
> goes to the devices you have chosen as defaults.
>
> PRIVATE BY DESIGN
> - Set a passphrase and every clip, file and image is encrypted on your device
>   with AES-256-GCM before it leaves. We store ciphertext and cannot read it.
> - The passphrase never leaves your devices. Adding a new one is a QR code
>   scanned from a device you already have.
> - No ads, no analytics, no tracking.
>
> BUILT FOR EVERY DAY
> - Recent history on every device, so a clip you missed is still there.
> - Text, links, images and files up to 10 MB.
> - Choose which devices receive each clip.
> - Sign in with Apple, Google or email to keep your history across devices
>   and reinstalls.
>
> GhostCopy for Mac is a free download from ghostcopy.app.

Update when it ships: add Windows to the last line.

## Age rating

Answer **None / No** to every content question - there is no violence,
sexual content, gambling, contests, medical content, user-to-user messaging or
unrestricted web browsing. Clips move only between the signed-in user's own
devices, so there is no user-generated content visible to others. Expected
result: 4+.

## App Privacy

Tracking: **No**. The app has no advertising or analytics SDK (checked
`pubspec.yaml`), Firebase is used for push delivery only, and Sentry receives
crash and error reports only (`lib/services/impl/crash_reporting_service.dart`: no
screenshots, no tracing, no IP, clip text stripped on the device).

| Data type | Collected | Linked to user | Purpose | Why |
|---|---|---|---|---|
| Contact Info - Email Address | Yes | Yes | App Functionality | Account upgrade, email, Google or Apple sign-in (Apple may give a relay address) |
| User Content - Photos or Videos | Yes | Yes | App Functionality | Images sent as clips |
| User Content - Other User Content | Yes | Yes | App Functionality | Clip text and files |
| Identifiers - User ID | Yes | Yes | App Functionality | Supabase account ID |
| Identifiers - Device ID | Yes | Yes | App Functionality | Push token per device, and the vendor-ID suffix in the device name |
| Contact Info - Name | Yes | Yes | App Functionality | Google sign-in asks for the profile scope, so Supabase stores the Google name (never shown by the app) |
| Diagnostics - Crash Data | Yes | **No** | App Functionality | Sentry crash reports; no user id is attached |
| Diagnostics - Other Diagnostic Data | Yes | **No** | App Functionality | Sentry error reports: device model, OS and app version, stack traces |
| Diagnostics - Performance Data | Yes | **No** | App Functionality | Sentry app-hang (iOS) and ANR (Android) reports - on by default, kept. Tracing is off |

Not collected: location, contacts, browsing history, search history, health,
financial info, purchases, usage data, sensitive info.

User content is declared even though it can be end-to-end encrypted: encryption
is optional, and without a passphrase the content is readable on the server.

## Export compliance

The app implements AES-256-GCM and PBKDF2-HMAC-SHA256 itself, in Dart, for
end-to-end encryption of user data - on top of HTTPS from the OS. That is not
the "only Apple's operating system encryption" case, so it is not exempt by
that route. Answers on the first upload:

1. Does your app use encryption? **Yes**
2. Algorithm type: **Standard encryption algorithms instead of, or in addition
   to, using or accessing the encryption within Apple's operating system**
3. Available on the French App Store? **No** for the first release - France
   requires a declaration to ANSSI for apps implementing their own
   encryption. File it, then add France under Pricing and Availability.

Do not set `ITSAppUsesNonExemptEncryption` to `NO`. Once App Store Connect has
the answers, add to `ios/Runner/Info.plist` whatever key(s) it asks for, so
later builds skip the prompt. Whether a US self-classification report applies
is a legal question - confirm rather than assume.

## Sign-in information for review

Sign-in required: **Yes** - provide a demo account. The iOS welcome screen has
no guest path: a new user signs in, signs up, or scans a QR code from the
desktop app, and email sign-up waits on a confirmation email the reviewer would
not receive.

There is no demo QR code to give, and none is needed. The QR is minted by the
desktop app on demand, expires after five minutes, is single-use, and is
useless without the 6-digit PIN shown beside it - a static image in the review
notes could not work, and a long-lived token that could would be a standing
way into the demo account. 1.0.8 (24) was rejected under 2.1(a) asking for one
anyway, because the welcome screen opened on a live camera headed "Scan QR".
From 1.0.10 it opens on Sign In and the QR tab is labelled optional; the notes
below say so up front.

Create it before submitting (for example `appreview@ghostcopy.app`, a real
inbox you control), confirm the email, and leave it with no passphrase so the
reviewer is not asked for one. Give it a few ordinary clips and a second
device (the Mac, linked by QR) so history and device targeting have something
to show. The same account is what the screenshots are taken with.

## Notes for the reviewer

> No QR code is needed to review this app. Sign in with the demo account
> above: on the first screen, the Sign In tab is already selected - enter the
> email and password and tap Login. Every feature is reachable from there.
>
> GhostCopy syncs the clipboard between a user's own devices, so its main
> feature needs a second device. The attached screen recording shows the full
> round trip between GhostCopy for Mac and an iPhone.
>
> To try it on one device: paste text into the composer and send. It appears
> in the history below. Sharing a photo or file to GhostCopy from the share
> sheet sends it the same way.
>
> The QR code is an optional shortcut for linking a phone to the desktop app.
> It is generated on demand by GhostCopy for Mac (Settings > Link New Device),
> expires after five minutes, can be used once, and only works together with
> the 6-digit PIN shown beside it - so a fixed demo QR code cannot be provided.
> If you want to try it: install the desktop app (free at
> https://ghostcopy.app/download), sign in with the same demo account, choose
> Link New Device, then on the iPad open the Scan QR tab and type the PIN.
>
> Encryption is optional and off by default. Setting a passphrase in Settings
> encrypts clips on the device before upload.
>
> Account deletion is in the app: Settings > Delete Account. It removes the
> account, its clips, stored files and linked devices, and for Sign in with
> Apple accounts revokes the app's Apple tokens.
>
> Push notifications are used only to deliver clips the user sent to this
> device. Tapping one copies the clip (text) or opens the share sheet (files).

## Reply to App Review - 1.0.8 (24), 2.1(a) demo QR code

Sent in Resolution Center with the 1.0.10 build attached to the version, and
the notes above pasted into App Review Information > Notes:

> Hello, and thank you for the review.
>
> GhostCopy does not need a QR code to be used or reviewed. The QR code is an
> optional shortcut for linking a phone to our desktop app: the desktop app
> generates it on demand, it expires after five minutes, it can be used once,
> and it only works together with a 6-digit PIN shown beside it. For that
> reason a fixed demo QR code or image cannot be provided.
>
> Please sign in with the demo account in App Review Information instead: on
> the first screen, select Sign In, enter the email and password, and tap
> Login. All features are available from there - send a clip from the
> composer, view history, share a photo or file to GhostCopy from the share
> sheet, and manage devices and the account in Settings.
>
> We understand the first screen made the QR code look required. In the new
> build the app opens on Sign In, and the QR tab is labelled as optional.
>
> A screen recording of the full flow between GhostCopy for Mac and an iPhone
> is attached.

## Screen recording for review (to record)

Keep it under a minute, show both screens in one take, no cuts:

1. The Mac with GhostCopy in the menu bar, iPhone beside it on screen or on
   camera.
2. Copy a line of text on the Mac, Option+Space, send.
3. The notification arrives on the iPhone; tap it; paste into Notes to prove it
   is on the clipboard.
4. On the iPhone, paste text into GhostCopy and send; it appears on the Mac.
5. Share a photo from Photos to GhostCopy; it arrives on the Mac.

## Screenshots

Required: 6.9" iPhone (1320 x 2868, iPhone 18 Pro Max simulator) and 13" iPad
(2064 x 2752, iPad Pro 13-inch simulator), because the app targets iPad.
Raw captures are in `docs/app-store-screenshots/`.

Screenshot protection does not affect captures on iOS: it only blurs the
app-switcher preview, and is off by default.
