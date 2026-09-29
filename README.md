<p align="center">
  <a href="https://ghostcopy.app/"><img src="website/icons/icon-512.png" width="112" height="112" alt="GhostCopy" /></a>
</p>

<h1 align="center">GhostCopy</h1>

<p align="center">
  <b>Copy on your computer. Paste on your phone.</b><br />
  A clipboard that follows you between devices &mdash; one keystroke, encrypted end to end,
  and nothing running while you are not using it.
</p>

<p align="center">
  <a href="https://ghostcopy.app/download/macos"><img src="https://img.shields.io/badge/Download_for_Mac-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for Mac" /></a>
  <a href="https://testflight.apple.com/join/62aWHQzj"><img src="https://img.shields.io/badge/iPhone-Join_the_TestFlight-0D96F6?style=for-the-badge&logo=appstore&logoColor=white" alt="iPhone on TestFlight" /></a>
  <a href="https://apps.microsoft.com/detail/9NW0TTGMSF80"><img src="https://img.shields.io/badge/Windows-Get_it_from_Microsoft-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Get it from Microsoft" /></a>
</p>

<p align="center">
  <a href="https://github.com/g1mliii/Ghostcopy/releases?q=macos&expanded=true"><img src="https://img.shields.io/github/downloads/g1mliii/Ghostcopy/total?style=flat-square&label=downloads&color=6670FF" alt="Downloads" /></a>
  <a href="https://github.com/g1mliii/Ghostcopy/releases?q=macos&expanded=true"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fg1mliii%2FGhostcopy%2Fbadges%2Fmacos-version.json&style=flat-square" alt="Latest macOS release" /></a>
  <a href="https://ghostcopy.app/"><img src="https://img.shields.io/badge/website-ghostcopy.app-6670FF?style=flat-square" alt="ghostcopy.app" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3A3A44?style=flat-square" alt="MIT licence" /></a>
</p>

---

## What it does

- **One keystroke on the desktop.** <kbd>Option</kbd>+<kbd>Space</kbd> on a Mac,
  <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> on Windows opens a small window over whatever you are
  doing. Paste, press Enter, and it is on your phone.
- **Tap to copy on the phone.** A clip from your computer arrives as a notification; tap it and it is
  on the phone's clipboard. Going the other way is paste-then-send, or the share sheet.
- **Files and photos too.** Up to 10 MB. iPhone photos are converted from HEIC to JPEG on the way
  out, so they open everywhere.
- **Encrypted end to end, if you want it.** Set a passphrase and clips are sealed on your device
  before they leave. The key never leaves your devices; a second device gets it by scanning a QR
  code.
- **Asleep until you need it.** While the window is hidden, animations and streams are paused, not
  throttled. It can sit in your menu bar or tray forever.
- **Reads what you copied.** JSON gets a prettify button, a JWT is decoded to its payload and
  expiry, a hex colour gets a swatch &mdash; offered, never applied behind your back.

## Get it

| Platform | Status | How |
|---|---|---|
| **macOS** 14+ | Available | [Download the .dmg](https://ghostcopy.app/download/macos) &mdash; signed and notarized by Apple, and keeps itself up to date |
| **iPhone** iOS 16+ | Public beta | [Join on TestFlight](https://testflight.apple.com/join/62aWHQzj) &mdash; install TestFlight, open the link on your iPhone, tap Accept |
| **Windows** 10/11 | Available | [Get it from the Microsoft Store](https://apps.microsoft.com/detail/9NW0TTGMSF80) &mdash; signed by Microsoft, and updates itself |
| **Android** 8+ | Next | [Get told when it lands](https://ghostcopy.app/download#notify) |

Everything else &mdash; the FAQ, privacy policy and terms &mdash; is at **[ghostcopy.app](https://ghostcopy.app/)**.

### Send a file from Windows Explorer

Right-click a file and choose **Send with GhostCopy**. It goes to your other devices without
opening the window, and a notification confirms it. Files can be up to 10 MB, and GhostCopy must
already be signed in.

---

## Building from source

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) (stable channel)
- A [Supabase](https://supabase.com) project (the free tier works)

### Set up

1. **Clone and fetch dependencies**
   ```bash
   git clone https://github.com/g1mliii/Ghostcopy.git
   cd Ghostcopy
   flutter pub get
   ```

2. **Create the database.** The schema lives in [`supabase/migrations/`](supabase/migrations/). Link
   the Supabase CLI to your project and push it:
   ```bash
   supabase link --project-ref <your-project-ref>
   supabase db push
   ```

3. **Point the app at your Supabase project**

   There is no `.env` file. Edit `_supabaseUrl` and `_supabasePublishableKey` at the
   top of `lib/main.dart`. A publishable key is public by design - the security
   boundary is Supabase's RLS policies, not hiding the key.

   For mobile builds you also need Firebase config, which is gitignored:
   `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`. For the iOS build-check workflow, add
   a repository Actions secret named `IOS_GOOGLE_SERVICE_INFO_PLIST` under
   **Settings → Secrets and variables → Actions → New repository secret**.
   Use the complete plist XML as its value (no base64 encoding); CI writes and
   validates the file before compiling. Desktop does not use FCM and needs
   neither.

4. **Run it**
   ```bash
   flutter run -d macos      # or windows, ios, android
   ```

   A release macOS build needs two Cargo variables; see `CLAUDE.md`. Shipping builds are made by the
   scripts in [`installer/`](installer/) &mdash; [`docs/macos-releases.md`](docs/macos-releases.md) is
   the macOS runbook.

## Tech stack

- **App:** Flutter (Dart 3) on macOS, Windows, iOS and Android, with native Swift and Kotlin where
  the platform needs it
- **Backend:** Supabase &mdash; PostgreSQL with row-level security, Realtime, Auth and Edge Functions
- **Delivery:** Firebase Cloud Messaging for push; Sparkle for macOS updates; MSIX through the
  Microsoft Store for Windows
- **Desktop:** window_manager, hotkey_manager, tray_manager
- **Crash reporting:** Sentry, with clip content stripped on the device before anything is sent

## License

MIT.
