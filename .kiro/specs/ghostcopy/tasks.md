# Implementation Plan

## Phase 1: Project Setup & Core Desktop Infrastructure

- [x] 1. Initialize Flutter project with multi-platform support
  - [x] 1.1 Create Flutter project with Windows, macOS, Android, iOS targets
    - Run `flutter create` with appropriate flags
    - Configure `pubspec.yaml` with core dependencies
    - _Requirements: 1.1, 2.1_
  - [x] 1.2 Set up project structure with service interfaces
    - Create `lib/services/`, `lib/models/`, `lib/repositories/`, `lib/ui/` directories
    - Define abstract interfaces for all services (IWindowService, IHotkeyService, etc.)
    - _Requirements: All_
  - [x] 1.3 Configure Supabase Flutter SDK
    - Add `supabase_flutter` dependency
    - Create Supabase initialization in main.dart
    - Set up environment configuration for Supabase URL and anon key
    - _Requirements: 5.1, 9.1_
  - [x] 1.4 Establish UI Design System should take inspiraton from blip app and discord
    - Create GhostColors class with dark theme palette
    - Create GhostTypography class with font styles
    - Set up ThemeData with design tokens
    - Add Inter and JetBrains Mono fonts
    - _Requirements: 12.1, 12.4_

- [ ] 2. Implement ClipboardItem data model
  - [ ] 2.1 Create ClipboardItem class with JSON serialization
    - Implement `toJson()` and `fromJson()` methods
    - Include all fields: id, userId, content, deviceName, deviceType, isPublic, createdAt
    - _Requirements: 5.3, 5.4_
  - [ ] 2.2 Write property test for ClipboardItem serialization round-trip

    - **Property 16: JSON Round-Trip** (applied to ClipboardItem)
    - **Validates: Requirements 7.5, 7.6**

- [ ] 3. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 2: Window Management & Hotkey System (Desktop)

- [ ] 4. Implement Window Manager Service
  - [ ] 4.1 Create WindowService implementation using window_manager package
    - Configure TitleBarStyle.hidden for borderless window
    - Implement show/hide/center/focus methods
    - Set up transparent background for rounded corners
    - _Requirements: 2.1, 2.2, 2.3_
  - [ ] 4.2 Implement window initialization with hidden state
    - App launches hidden by default
    - Window appears centered when triggered
    - _Requirements: 2.1, 1.1_

- [ ] 5. Implement Hotkey Service
  - [ ] 5.1 Create HotkeyService implementation using hotkey_manager package
    - Register global hotkey (configurable, default Ctrl+Shift+S)
    - Handle hotkey callback to show Spotlight window
    - _Requirements: 1.1, 3.4_
  
- [ ] 6. Implement System Tray Service
  - [ ] 6.1 Create TrayService implementation using tray_manager package
    - Set up tray icon
    - Create context menu with Quit option, Game Mode toggle, and Settings
    - _Requirements: 2.2, 2.4, 2.5, 6.4_

- [ ] 7. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 3: Spotlight UI & Clipboard Operations

- [ ] 8. Build Spotlight Window UI
  - [ ] 8.1 Create SpotlightWindow widget with TextField and Send button
    - Glassmorphism background with blur effect (500px wide, 12px border radius)
    - Auto-focus text field on appear
    - Handle Enter to send, Escape to close
    - Smooth fade + scale animation on appear (150ms ease-out)
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 12.1, 12.2_
  - [ ] 8.2 Implement keyboard navigation for Spotlight
    - Tab navigation between elements
    - Arrow keys for transformer options
    - _Requirements: 12.5_
- [ ] 9. Implement Clipboard Repository
  - [ ] 9.1 Create ClipboardRepository with Supabase operations
    - Implement insert() with device metadata
    - Implement watchHistory() with Realtime stream
    - Implement getHistory() with limit and sort
    - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - [ ]* 9.2 Write property test for history limit enforcement
    - **Property 5: History Limit Enforcement**
    - **Validates: Requirements 4.1**
  - [ ]* 9.3 Write property test for history sort order
    - **Property 6: History Sort Order**
    - **Validates: Requirements 4.2**
  - [ ]* 9.4 Write property test for device metadata completeness
    - **Property 8: Device Metadata Completeness**
    - **Validates: Requirements 5.3**
  - [ ]* 9.5 Write property test for user ID association
    - **Property 9: User ID Association**
    - **Validates: Requirements 5.4**

- [ ] 10. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 4: Lifecycle & Sleep Mode

- [ ] 11. Implement Lifecycle Controller
  - [ ] 11.1 Create LifecycleController for Sleep Mode management
    - Track isSleeping state
    - Implement enterSleepMode() and exitSleepMode()
    - Manage list of Pausable resources
    - _Requirements: 3.1, 3.2, 3.3_
  - [ ] 11.2 Write property test for sleep mode resource pausing

    - **Property 2: Sleep Mode Resource Pausing**
    - **Validates: Requirements 3.1, 3.2**
  - [ ] 11.3 Write property test for sleep mode round-trip

    - **Property 3: Sleep Mode Round-Trip**
    - **Validates: Requirements 3.3**

- [ ] 12. Integrate lifecycle with window visibility
  - [ ] 12.1 Wire LifecycleController to WindowService events
    - Enter sleep mode when window hides
    - Exit sleep mode when window shows
    - Ensure hotkey listener remains active during sleep
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [ ] 13. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 5: Smart Transformers

- [ ] 14. Implement Transformer Service
  - [ ] 14.1 Create content type detection logic
    - Detect valid JSON strings
    - Detect JWT tokens (three dot-separated base64 segments)
    - Detect hex color codes (#RGB, #RRGGBB, #RRGGBBAA)
    - _Requirements: 7.1, 7.2, 7.3_
  - [ ] 14.2 Write property test for JSON detection

    - **Property 13: JSON Detection**
    - **Validates: Requirements 7.1**
  - [ ] 14.3 Write property test for JWT detection and decoding

    - **Property 14: JWT Detection and Decoding**
    - **Validates: Requirements 7.2**
  - [ ] 14.4 Write property test for hex color detection

    - **Property 15: Hex Color Detection**
    - **Validates: Requirements 7.3**

- [ ] 15. Implement JSON prettifier
  - [ ] 15.1 Create prettifyJson() function with proper indentation
    - Parse JSON, format with 2-space indentation
    - Handle nested objects and arrays
    - _Requirements: 7.4, 7.5, 7.6_
  - [ ] 15.2 Write property test for JSON round-trip

    - **Property 16: JSON Round-Trip**
    - **Validates: Requirements 7.5, 7.6**

- [ ] 16. Implement JWT decoder
  - [ ] 16.1 Create decodeJwt() function using dart_jsonwebtoken
    - Extract payload claims
    - Parse expiration date and user ID
    - Handle invalid tokens gracefully
    - _Requirements: 7.2_

- [ ] 17. Integrate transformers into Spotlight UI
  - [ ] 17.1 Add transformer buttons and previews to SpotlightWindow
    - Show Prettify button for JSON content
    - Show decoded payload for JWT tokens
    - Show color square for hex codes
    - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [ ] 18. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 6: Game Mode

- [ ] 19. Implement Game Mode Service
  - [ ] 19.1 Create GameModeService with notification queuing
    - Track isActive state
    - Implement toggle() method
    - Queue notifications when active
    - Flush queue when deactivated
    - _Requirements: 6.1, 6.2, 6.3, 6.4_
  - [ ]* 19.2 Write property test for notification queuing
    - **Property 10: Game Mode Notification Queuing**
    - **Validates: Requirements 6.1**
  - [ ]* 19.3 Write property test for send invariant during game mode
    - **Property 11: Game Mode Send Invariant**
    - **Validates: Requirements 6.2**
  - [ ]* 19.4 Write property test for queue flush
    - **Property 12: Game Mode Queue Flush**
    - **Validates: Requirements 6.3**

- [ ] 20. Integrate Game Mode with tray menu
  - [ ] 20.1 Add Game Mode toggle to tray context menu
    - Update tray menu to show current state
    - Wire toggle to GameModeService
    - _Requirements: 6.4_

- [ ] 21. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 7: Desktop Auto-Receive

- [ ] 22. Implement Auto-Receive Service
  - [ ] 22.1 Create AutoReceiveService for desktop clipboard population
    - Subscribe to Realtime clipboard changes
    - Filter out items from current device
    - Copy received content to system clipboard
    - Show subtle toast notification (unless Game Mode active)
    - _Requirements: 11.1, 11.2, 11.3_
  - [ ]* 22.2 Write property test for desktop auto-receive
    - **Property 19: Desktop Auto-Receive**
    - **Validates: Requirements 11.1**
  - [ ]* 22.3 Write property test for auto-receive deduplication
    - **Property 20: Auto-Receive Deduplication**
    - **Validates: Requirements 11.4**

- [ ] 23. Implement deduplication logic
  - [ ] 23.1 Add debounce/throttle for rapid incoming items
    - Only copy most recent item when multiple arrive quickly
    - Prevent clipboard thrashing
    - _Requirements: 11.4_

- [ ] 24. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 8: Authentication

- [ ] 25. Implement Authentication Flow
  - [ ] 25.1 Create auth screens (login/signup)
    - Email/password authentication via Supabase Auth
    - Persist session for auto-login
    - _Requirements: 9.1_
  - [ ] 25.2 Implement auth state management
    - Check auth state on app launch
    - Redirect to login if not authenticated
    - Enable sync features only after auth
    - _Requirements: 9.1_
  - [ ]* 25.3 Write property test for user data isolation
    - **Property 17: User Data Isolation**
    - **Validates: Requirements 9.2, 9.3**

- [ ] 26. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 9: Auto-Start & Polish

- [ ] 27. Implement Auto-Start
  - [ ] 27.1 Configure launch_at_startup package
    - Register app to start at OS login
    - Launch in hidden/sleep mode
    - _Requirements: 10.1, 10.2_

- [ ] 28. Clipboard History UI
  - [ ] 28.1 Build history list view
    - Scrollable list with staggered fade-in animation
    - Truncated previews for long content with expand option
    - Tap to copy functionality with hover effects
    - Toast notification slides in from bottom-right
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 12.3, 12.4_
  - [ ]* 28.2 Write property test for realtime history update
    - **Property 7: Realtime History Update**
    - **Validates: Requirements 5.2**

- [ ] 29. Settings Screen
  - [ ] 29.1 Build settings UI
    - Hotkey customization with key capture
    - Auto-start toggle switch
    - Device name text field
    - Dark theme consistent with design system
    - _Requirements: 13.1, 13.2, 13.3_

- [ ] 30. Desktop Security Review & Memory Leak Testing
  - [ ] 30.1 Conduct security review
    - Review RLS policies in Supabase
    - Verify .env file is in .gitignore
    - Check for exposed API keys or secrets in code
    - Validate input sanitization for clipboard content
    - Test authentication flow for vulnerabilities
  - [ ] 30.2 Memory leak testing
    - Use Flutter DevTools to profile memory usage
    - Test sleep mode transitions for memory leaks
    - Verify stream subscriptions are properly disposed
    - Check for retained references in lifecycle controller
    - Test long-running app scenarios (24+ hours)

- [ ] 31. Final Desktop Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 10: macOS Port

- [ ] 31. Configure macOS-specific features
  - [ ] 31.1 Set up macOS App Sandbox entitlements
    - Enable Network Client capability
    - Configure accessibility permissions request on startup (required for global hotkeys)
    - _Requirements: 1.1, 3.4_
  - [ ] 31.2 Verify tray_manager works in macOS Menu Bar
    - Test icon appearance and context menu
    - _Requirements: 2.2, 2.4_

- [ ] 32. Checkpoint - Ensure macOS build works
  - Ensure all tests pass, ask the user if questions arise.

## Phase 11: Mobile App

- [ ] 33. Build Mobile Receiver UI
  - [ ] 33.1 Create mobile app main screen
    - History list with same design language (dark theme, glassmorphism cards)
    - Prominent paste area for sending with clear CTA
    - Send button for paste-to-send flow
    - Staggered animations consistent with desktop
    - _Requirements: 8.1, 8.2, 8.3, 8.6, 8.7, 8.8, 12.1_
  - [ ]* 33.2 Write property test for mobile send with device type
    - **Property 18: Mobile Send with Device Type**
    - **Validates: Requirements 8.7**

- [ ] 34. Implement Push Notifications
  - [ ] 34.1 Configure flutter_local_notifications
    - Set up notification channels
    - Handle notification tap to open app and copy
    - _Requirements: 8.1, 8.2, 8.3_
  - [ ] 34.2 Integrate Firebase Cloud Messaging (FCM) with Supabase
    - Add firebase_messaging package
    - Configure FCM for Android and iOS
    - Store FCM tokens in Supabase
    - Set up Supabase Edge Function or database trigger to send push notifications via FCM
    - _Requirements: 8.1_

- [ ] 35. Implement Home Screen Widget
  - [ ] 35.1 Configure home_widget package
    - Display 5 most recent clips in scrollable list
    - Update widget when new clips arrive
    - Dark theme consistent with app
    - _Requirements: 8.4, 8.5_

- [ ] 36. Mobile Security Review & Memory Leak Testing
  - [ ] 36.1 Conduct mobile security review
    - Review FCM token storage and handling
    - Verify clipboard data is cleared after auto-copy
    - Test notification permissions and handling
    - Validate widget data security
    - Check for background process vulnerabilities
  - [ ] 36.2 Mobile memory leak testing
    - Profile memory usage on Android and iOS
    - Test widget updates for memory leaks
    - Verify notification listeners are properly disposed
    - Test app backgrounding/foregrounding scenarios

- [ ] 37. Final Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Phase 12: Landing Page & Distribution

- [ ] 38. Build Landing Page
  - [ ] 38.1 Create simple landing page
    - Hero section with GhostCopy branding and tagline
    - Feature highlights (cross-platform, realtime, secure)
    - Download buttons for Windows and macOS
    - Screenshots/demo video
    - Dark theme consistent with app design
  - [ ] 38.2 Set up hosting
    - Deploy to Vercel, Netlify, or GitHub Pages
    - Configure custom domain (optional)
    - Set up analytics (optional)

- [ ] 39. Prepare Distribution Builds
  - [ ] 39.1 Create Windows installer
    - Build release executable
    - Create installer with NSIS or Inno Setup
    - Code sign the executable (optional but recommended)
  - [ ] 39.2 Create macOS app bundle
    - Build release .app
    - Create DMG installer
    - Notarize with Apple (required for distribution)
  - [ ] 39.3 Prepare mobile app store submissions
    - Build release APK/AAB for Android
    - Build release IPA for iOS
    - Prepare app store listings and screenshots

- [ ] 40. Landing Page Security Review
  - [ ] 40.1 Review landing page security
    - Verify HTTPS is enabled
    - Check for XSS vulnerabilities
    - Validate download links point to correct files
    - Test download integrity (checksums)
    - Review privacy policy and terms (if applicable)
