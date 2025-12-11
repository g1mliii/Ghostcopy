# GhostCopy Development Guidelines

## Project Overview
GhostCopy is a cross-platform clipboard synchronization tool built with Flutter. It runs as an invisible background utility on desktop (Windows/macOS) and as a receiver app on mobile (iOS/Android).

## Tech Stack
- **Framework:** Flutter (Stable Channel)
- **Backend:** Supabase (PostgreSQL + Realtime + Auth)
- **Language:** Dart 3.x
- **Testing:** flutter_test + glados (property-based testing)

## Key Packages
| Package | Purpose |
|---------|---------|
| `supabase_flutter` | Auth, Database, Realtime |
| `window_manager` | Borderless window, hide/show |
| `hotkey_manager` | Global keyboard shortcuts |
| `tray_manager` | System tray icon and menu |
| `launch_at_startup` | Auto-start on login |
| `flutter_local_notifications` | Mobile push notifications |
| `home_widget` | iOS/Android home screen widgets |
| `dart_jsonwebtoken` | JWT decoding |

## Architecture Principles

### Service-Based Architecture
- All features are implemented as services with abstract interfaces
- Services are injected via dependency injection for testability
- Example: `IWindowService`, `IHotkeyService`, `IClipboardRepository`

### Sleep Mode (Zero-CPU)
When the Spotlight window is hidden:
- Pause all TickerProviders (animations)
- Stop non-essential stream subscriptions
- Keep only the hotkey listener active

### Bidirectional Sync
- **Desktop → Mobile:** Hotkey triggers Spotlight, user sends, mobile receives push notification
- **Mobile → Desktop:** User pastes into app, taps Send, desktop auto-receives and copies to clipboard

## UI Design Language

### Theme: Dark + Glassmorphism
Inspired by Discord and Blip - modern, sleek, premium feel.

### Colors
```dart
background: Color(0xFF0D0D0F)      // Deep black
surface: Color(0xFF1A1A1D)         // Card surfaces
primary: Color(0xFF5865F2)         // Purple-blue accent
success: Color(0xFF3BA55C)         // Green confirmations
textPrimary: Color(0xFFFFFFFF)
textSecondary: Color(0xFFB9BBBE)
```

### Typography
- Primary font: Inter
- Monospace: JetBrains Mono (for code/JSON)

### Animations
- Spotlight appear: Fade + scale from 0.95 (150ms ease-out)
- Button hover: Scale 1.02 + brightness
- Toast: Slide in from bottom-right
- History items: Staggered fade-in

### Spotlight Window Specs
- Width: 500px, auto-height (max 400px)
- Border radius: 12px
- Background: Glassmorphism with blur
- Shadow: Subtle drop shadow

## Code Style

### Naming Conventions
- Services: `XxxService` (e.g., `WindowService`)
- Repositories: `XxxRepository` (e.g., `ClipboardRepository`)
- Models: PascalCase (e.g., `ClipboardItem`)
- Files: snake_case (e.g., `clipboard_item.dart`)

### File Structure
```
lib/
├── main.dart
├── app.dart
├── models/
│   └── clipboard_item.dart
├── services/
│   ├── window_service.dart
│   ├── hotkey_service.dart
│   ├── tray_service.dart
│   ├── lifecycle_controller.dart
│   ├── transformer_service.dart
│   ├── game_mode_service.dart
│   └── auto_receive_service.dart
├── repositories/
│   └── clipboard_repository.dart
├── ui/
│   ├── theme/
│   │   ├── colors.dart
│   │   └── typography.dart
│   ├── widgets/
│   │   └── ...
│   └── screens/
│       ├── spotlight_window.dart
│       ├── history_screen.dart
│       └── settings_screen.dart
└── utils/
    └── ...
```

### Testing
- Unit tests: `test/unit/`
- Property tests: `test/property/`
- Tag property tests with: `**Feature: ghostcopy, Property {N}: {description}**`
- Run minimum 100 iterations for property tests

## Supabase Configuration

### Required Dashboard Setup
1. **Realtime:** Enable INSERT and UPDATE on `clipboard` table
2. **RLS:** Policies auto-created by schema, verify they're active
3. **Auth:** Enable email/password provider

### Environment Variables
```
SUPABASE_URL=your-project-url
SUPABASE_ANON_KEY=your-anon-key
```

## Platform-Specific Notes

### Windows
- Hotkeys work globally via `hotkey_manager`
- Tray icon appears in system notification area
- No special permissions needed

### macOS
- Requires Accessibility permissions for global hotkeys
- Prompt user on first launch
- Tray icon appears in Menu Bar
- Configure App Sandbox entitlements for network

### Mobile (iOS/Android)
- Cannot auto-detect clipboard changes (OS restriction)
- Use paste-to-send flow instead
- Push notifications require FCM/APNs setup
