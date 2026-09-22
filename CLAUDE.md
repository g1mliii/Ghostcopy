# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow & Operating Principles

**See [`docs/workflow.md`](docs/workflow.md)** for complete workflow orchestration, operating principles, task management, and engineering best practices.

**Key supporting files:**
- [`tasks/todo.md`](tasks/todo.md) - Current work and task tracking
- [`tasks/lessons.md`](tasks/lessons.md) - Lessons learned from mistakes and corrections

---
## Project Overview

GhostCopy is a cross-platform clipboard synchronization tool built with Flutter. Desktop (Windows/macOS) runs as an invisible background utility with a "Spotlight-style" popup triggered by global hotkey. Mobile (iOS/Android) serves as a receiver with push notifications.

## Build & Development Commands

```bash
# Get dependencies
flutter pub get

# Run on specific platform
flutter run -d windows
flutter run -d macos
flutter run -d android
flutter run -d ios

# Build release
flutter build windows
flutter build apk
flutter build ios

# macOS needs these two, or Cargokit fails at exit 101 compiling
# super_native_extensions before any Swift is built: a stripped Rust
# proc-macro dylib will not load on newer macOS toolchains. A bare
# `flutter build macos` is the one command here that does not work.
CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=true CARGO_PROFILE_RELEASE_STRIP=none \
  flutter build macos --release

# For an actual release, use the script instead - it exports those, archives
# and exports with the Developer ID profile, notarizes, staples and packages.
installer/macos/build-release.sh NOTARY_KEYCHAIN_PROFILE

# Run tests
flutter test

# Run single test file
flutter test test/unit/services/transformer_service_test.dart

# Analyze code
flutter analyze
```

## Architecture

### Client-Server Model
- **Backend**: Supabase (PostgreSQL + Realtime + Auth + RLS)
- **Sync**: Bidirectional via Supabase Realtime subscriptions
- **Auth**:
  - Anonymous sign-in by default
  - Upgrade to email/password or Google OAuth
  - Preserves user_id and clipboard data during upgrade
  - See `GOOGLE_OAUTH_SETUP.md` for Google OAuth configuration

### Service-Based Architecture
All features are implemented as services with abstract interfaces for testability:
- `IWindowService` - Borderless window management, show/hide Spotlight
- `IHotkeyService` - Global keyboard shortcut registration
- `ITrayService` - System tray icon and context menu
- `IClipboardRepository` - Supabase CRUD operations
- `ILifecycleController` - Sleep Mode resource management
- `ITransformerService` - Content type detection (JSON, JWT, hex colors)
- `IGameModeService` - Notification suppression during fullscreen apps
- `IAutoReceiveService` - Desktop auto-copy from other devices

### ViewModel Pattern (ChangeNotifier + GetIt)
- Use `ChangeNotifier` ViewModels for screen-level business logic:
  - `SpotlightViewModel` (`lib/ui/viewmodels/spotlight_viewmodel.dart`)
  - `MobileMainViewModel` (`lib/ui/viewmodels/mobile_main_viewmodel.dart`)
- Keep UI-only concerns inside widgets:
  - Animation controllers / `TickerProvider`
  - `TextEditingController` and `FocusNode`
  - Panel routing and transient presentation state
- Keep business concerns in ViewModels:
  - Send/receive orchestration
  - History loading/filtering
  - Device targeting and security checks
  - Timer/cache lifecycle and cleanup
- Binding pattern:
  - Resolve ViewModel with GetIt in `initState`
  - Register one listener and coalesce UI rebuilds when needed
  - Remove listener and dispose ViewModel in `dispose`
- Testing rule: new ViewModel logic requires unit tests with mocked services.

### Key Patterns

**Sleep Mode (Zero-CPU)**: When Spotlight is hidden, pause all TickerProviders and non-essential streams. Only hotkey listener stays active. Implement `Pausable` interface for pausable resources.

**Bidirectional Sync Flow**:
- Desktop → Mobile: Hotkey → Spotlight → Send → Push notification → Auto-copy
- Mobile → Desktop: Paste into app → Send → Realtime → Auto-copy to clipboard

**Smart Transformers**: Detect content types and offer enhancements:
- JSON: Prettify button with 2-space indentation
- JWT: Decode and display payload/expiration
- Hex colors: Show color preview square

## UI Design System

**Theme**: Dark + glassmorphism

These are the real values from `lib/ui/theme/colors.dart` - check there first.
This block was stale for a while and read #5865F2, which is Discord's Blurple
verbatim; the launch screens were built against the old background from here
and ended up a shade off the app they hand over to.

**Colors** (see `lib/ui/theme/colors.dart`):
```dart
background: Color(0xFF0F0F13)    // Deep black
surface: Color(0xFF19191F)       // Card surfaces
primary: Color(0xFF6670FF)       // Purple-blue accent
success: Color(0xFF3BA55C)       // Green confirmations
```

**Typography**: Inter for UI, JetBrains Mono for code/JSON

**Spotlight Window (Desktop)**: 500px wide, max 400px height, 12px border radius, discord and blip as inspiration.

**Mobile UI**: History list with glassmorphism cards, prominent paste area with clear CTA, send button. Same dark theme and staggered animations as desktop.

**Animations**:
- Spotlight appear: fade + scale from 0.95 (150ms ease-out)
- Button hover: scale 1.02 + brightness
- Toast: slide in from bottom-right
- History items: staggered fade-in

## Project Structure

```
lib/
├── main.dart
├── models/           # Data models (ClipboardItem, AppState)
├── services/         # Business logic services
├── repositories/     # Data access layer (Supabase)
└── ui/
    ├── theme/        # Colors, typography, app theme
    ├── widgets/      # Reusable components
    └── screens/      # Full screens (spotlight, history, settings)

test/
├── unit/             # Unit tests
└── property/         # Property-based tests (glados)
```

## Testing

- **Framework**: `flutter_test` + `glados` for property-based testing
- **Property tests**: Minimum 100 iterations, tag with `**Feature: ghostcopy, Property N: description**`
- Use `const` widgets where possible to reduce rebuilds

### Mobile-Specific Testing
- **Memory Profiling**: Test notification listeners and app backgrounding/foregrounding scenarios
- **Security Review Checklist**:
  - FCM token storage and handling
  - Clipboard data clearing after auto-copy
  - Notification permissions validation
  - Widget data security
  - Background process vulnerabilities

## Key Packages

| Package | Purpose |
|---------|---------|
| `supabase_flutter` | Auth, Database, Realtime |
| `window_manager` | Borderless window, hide/show (desktop) |
| `hotkey_manager` | Global keyboard shortcuts (desktop) |
| `tray_manager` | System tray icon and menu (desktop) |
| `launch_at_startup` | Auto-start on login (desktop) |
| `dart_jsonwebtoken` | JWT decoding |
| `glados` | Property-based testing |
| `flutter_local_notifications` | Notification channels (mobile) |
| `firebase_messaging` | FCM push notifications (mobile) |

## Environment Setup

**There is no `.env` file.** The Supabase URL and publishable key are
compile-time constants at the top of `lib/main.dart`. That is deliberate: a
publishable key is public by design, and the security boundary is Supabase's
RLS policies, not concealment of the key.

It is the `sb_publishable_...` key from Supabase's current API key scheme, not
the legacy `anon` JWT. Do not disable legacy API keys until every released
build carries the publishable key - it is compiled in, so an old install keeps
sending whatever it shipped with. The server-side counterpart is the
`sb_secret_...` key: `SUPABASE_SERVICE_ROLE_KEY` in an Edge Function now holds
that, and the `fcm_service_role_key` vault secret the notification trigger
sends must match it byte for byte or `send-clipboard-notification` returns 401
and push stops with nothing surfacing the failure.

Two config files are gitignored and must be copied across (or re-downloaded
from the Firebase console) when setting up a new machine for mobile work:

- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`

Neither is needed for Windows, macOS or Linux - desktop does not use FCM. CI
builds Android against `.github/ci/google-services.placeholder.json`.

For Google OAuth setup, see `left_TO_DO/GOOGLE_OAUTH_SETUP.md`.

## MCP Servers

### Cloudflare Code Mode MCP
**Server URL**: `https://mcp.cloudflare.com/mcp`

The Cloudflare Code Mode MCP provides access to the entire Cloudflare API (2,500+ endpoints) through a highly efficient interface:
- **`search()`** - Query the OpenAPI specification programmatically to discover API capabilities
- **`execute()`** - Write authenticated JavaScript code to make API calls and chain operations

Both tools execute in a secure V8 sandbox isolate with no file system access. Use this MCP for any Cloudflare API integration needs—it reduces token usage by 99.9% compared to traditional MCP implementations.

**Authorization**: OAuth 2.1

## Platform Notes

**Windows**: Hotkeys and tray work out of the box

**macOS**: Distribution is a Developer ID archive/export plus a notarized
drag-to-install DMG, and updates ship through Sparkle over a signed appcast.
See [`docs/macos-releases.md`](docs/macos-releases.md) for the release runbook
and `installer/macos/` for the scripts.

Global hotkeys use Carbon's `RegisterEventHotKey` (via `hotkey_manager`), which does not require Accessibility permission — do not add an `AXIsProcessTrustedWithOptions` prompt. The app is sandboxed (`com.apple.security.app-sandbox`), so it could not hold Accessibility trust even if it asked. Configure App Sandbox entitlements for network access.

**Mobile (iOS/Android)**:
- Cannot auto-detect clipboard changes (OS restriction)
- Use paste-to-send flow with prominent paste area and send button
- **Push Notifications**: FCM for Android, APNs for iOS via Firebase Cloud Messaging
  - FCM tokens stored in Supabase user table
  - Supabase Edge Function or database trigger sends notifications on new clipboard items
  - Notification tap opens app and auto-copies content (Android copies silently
    via CopyActivity when the background isolate staged the clip)
- **No home screen widget.** One existed and was removed: an iOS widget
  extension cannot write the general pasteboard on a real device (measured -
  the staged file read back fine and `UIPasteboard.general.string` did not hold
  the value microseconds later, in-process), so tapping a clip could only open
  the app. That is barely more than the notification tap already does, and the
  Android half was not worth maintaining alone.
- **UI Design**: Glassmorphism cards, dark theme, staggered animations consistent with desktop

## Database Schema

```sql
CREATE TABLE clipboard (
  id bigint PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
  user_id uuid REFERENCES auth.users NOT NULL,
  content text NOT NULL,
  device_name text,
  device_type text NOT NULL,  -- 'windows', 'macos', 'android', 'ios'
  is_public boolean DEFAULT false,
  created_at timestamptz DEFAULT timezone('utc', now())
);

-- RLS enabled with user-scoped policies

-- Note: FCM tokens for push notifications are stored in Supabase
-- (implementation may use a separate devices table or extend auth.users metadata)
```

## Implementation Status

See `new text document.txt` for full implementation plan with checkboxes.
