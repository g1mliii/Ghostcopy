# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow & Operating Principles

**See [`docs/workflow.md`](docs/workflow.md)** for complete workflow orchestration, operating principles, task management, and engineering best practices.

**Key supporting files:**
- [`tasks/todo.md`](tasks/todo.md) - Current work and task tracking
- [`tasks/lessons.md`](tasks/lessons.md) - Lessons learned from mistakes and corrections

---
## Project Overview

GhostCopy is a cross-platform clipboard synchronization tool built with Flutter. Desktop (Windows/macOS) runs as an invisible background utility with a "Spotlight-style" popup triggered by global hotkey. Mobile (iOS/Android) serves as a receiver with push notifications and home screen widgets.

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
flutter build macos
flutter build apk
flutter build ios

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

**Theme**: Dark + glassmorphism, inspired by Discord and Blip

**Colors** (see `lib/ui/theme/colors.dart`):
```dart
background: Color(0xFF0D0D0F)    // Deep black
surface: Color(0xFF1A1A1D)       // Card surfaces
primary: Color(0xFF5865F2)       // Purple-blue accent (Discord-like)
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
- **Memory Profiling**: Test widget updates, notification listeners, and app backgrounding/foregrounding scenarios
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
| `home_widget` | Home screen widget (mobile) |

## Environment Setup

Create `.env` file in project root:
```
SUPABASE_URL=your-project-url
SUPABASE_ANON_KEY=your-anon-key
GOOGLE_CLIENT_ID=your-google-client-id.apps.googleusercontent.com  # Optional, for Google OAuth
```

For Google OAuth setup, see `GOOGLE_OAUTH_SETUP.md`.

## Platform Notes

**Windows**: Hotkeys and tray work out of the box

**macOS**: Requires Accessibility permissions for global hotkeys. Configure App Sandbox entitlements for network access.

**Mobile (iOS/Android)**:
- Cannot auto-detect clipboard changes (OS restriction)
- Use paste-to-send flow with prominent paste area and send button
- **Push Notifications**: FCM for Android, APNs for iOS via Firebase Cloud Messaging
  - FCM tokens stored in Supabase user table
  - Supabase Edge Function or database trigger sends notifications on new clipboard items
  - Notification tap opens app and auto-copies content
- **Home Screen Widget**: Displays 5 most recent clips in scrollable list, auto-updates via `home_widget` package
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
