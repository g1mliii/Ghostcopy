# Requirements Document

## Introduction

GhostCopy is a universal clipboard synchronization tool that enables seamless, real-time text sharing across devices. The application runs as an invisible background utility on desktop platforms (Windows/macOS) and provides instant clipboard access on mobile devices (iOS/Android). The core experience prioritizes speed, invisibility, and intelligent handling of developer-focused data types like JSON and JWT tokens.

## Glossary

- **GhostCopy System**: The complete cross-platform clipboard synchronization application
- **Spotlight Window**: A borderless, centered popup window that appears when the user triggers the global hotkey
- **Global Hotkey**: A system-wide keyboard shortcut (configurable, default Ctrl+Shift+S) that activates GhostCopy regardless of the focused application
- **Clipboard Item**: A single piece of text content stored in the synchronization history
- **Sleep Mode**: A low-power state where the application pauses all animations and non-essential processing
- **Game Mode**: A user-toggled or auto-detected state that suppresses visual notifications during full-screen applications
- **Smart Transformer**: A feature that detects and enhances specific data formats (JSON, JWT, Hex colors)
- **System Tray**: The notification area in the operating system taskbar where background applications display icons
- **Design Language**: Modern, sleek dark-themed UI inspired by Discord and Blip - featuring glassmorphism, subtle animations, and clean typography

## Requirements

### Requirement 1: Ghost Send (Desktop Clipboard Capture)

**User Story:** As a desktop user, I want to quickly send copied text to the cloud using a global hotkey, so that I can access it on my other devices without interrupting my workflow.

#### Acceptance Criteria

1. WHEN a user presses shortcut THEN the GhostCopy System SHALL display the Spotlight Window centered on the screen within 200 milliseconds
2. WHEN the Spotlight Window appears THEN the GhostCopy System SHALL automatically populate the text field with the current system clipboard content
3. WHEN the Spotlight Window appears THEN the GhostCopy System SHALL focus the text input field for immediate editing
4. WHEN a user presses Enter in the Spotlight Window THEN the GhostCopy System SHALL send the text content to Supabase and close the window within 500 milliseconds
5. WHEN a user presses Escape in the Spotlight Window THEN the GhostCopy System SHALL close the window without sending any data

### Requirement 2: Invisible Window Management

**User Story:** As a desktop user, I want the application to run invisibly in the background, so that it does not clutter my screen or taskbar.

#### Acceptance Criteria

1. WHEN the GhostCopy System starts THEN the GhostCopy System SHALL launch in a hidden state with no visible window
2. WHEN the GhostCopy System is running THEN the GhostCopy System SHALL display only a system tray icon as its visible presence
3. WHEN the Spotlight Window is displayed THEN the GhostCopy System SHALL render a borderless window with no title bar or window controls
4. WHEN a user right-clicks the system tray icon THEN the GhostCopy System SHALL display a context menu with a Quit option and settings
5. WHEN a user selects Quit from the tray menu THEN the GhostCopy System SHALL terminate the application process

### Requirement 3: Zero-CPU Sleep Mode

**User Story:** As a gamer or power user, I want the application to consume zero CPU resources when hidden, so that it does not impact system performance.

#### Acceptance Criteria

1. WHEN the Spotlight Window is hidden THEN the GhostCopy System SHALL pause all animation TickerProviders
2. WHEN the Spotlight Window is hidden THEN the GhostCopy System SHALL stop all non-essential stream subscriptions
3. WHEN the Spotlight Window becomes visible THEN the GhostCopy System SHALL resume all paused animations and streams within 50 milliseconds
4. WHILE the GhostCopy System is in Sleep Mode THEN the GhostCopy System SHALL maintain the global hotkey listener active

### Requirement 4: Clipboard History (The Stash)

**User Story:** As a user, I want to view my clipboard history, so that I can access previously copied items.

#### Acceptance Criteria

1. WHEN a user opens the main application view THEN the GhostCopy System SHALL display a the frist few items than a show more which will open a list of the most recent 25 clipboard items
2. WHEN displaying clipboard history THEN the GhostCopy System SHALL sort items by creation date with newest items first
3. WHEN a user taps a history item THEN the GhostCopy System SHALL copy that item's content to the local system clipboard
4. WHEN a clipboard item is copied from history THEN the GhostCopy System SHALL display a confirmation toast message

### Requirement 5: Real-time Synchronization

**User Story:** As a multi-device user, I want clipboard items to sync automatically across all my devices, so that I can seamlessly continue my work.

#### Acceptance Criteria

1. WHEN a clipboard item is inserted into Supabase THEN the GhostCopy System SHALL broadcast the change to all connected devices via Realtime subscription
2. WHEN a device receives a new clipboard item THEN the GhostCopy System SHALL update the local history list without requiring manual refresh
3. WHEN sending a clipboard item THEN the GhostCopy System SHALL include the device name and device type metadata
4. WHEN a clipboard item is stored THEN the GhostCopy System SHALL associate the item with the authenticated user's ID for privacy

### Requirement 6: Game Mode Protection

**User Story:** As a gamer, I want incoming clipboard notifications to be suppressed during full-screen applications, so that my gaming experience is not interrupted.

#### Acceptance Criteria

1. WHILE Game Mode is active THEN the GhostCopy System SHALL queue incoming clipboard notifications without displaying visual alerts
2. WHILE Game Mode is active THEN the GhostCopy System SHALL continue to allow sending clipboard items via the global hotkey
3. WHEN Game Mode is deactivated THEN the GhostCopy System SHALL display queued notifications in sequence
4. WHEN a user toggles Game Mode in the tray menu THEN the GhostCopy System SHALL immediately switch between active and inactive states

### Requirement 7: Smart Transformers

**User Story:** As a developer, I want the application to detect and enhance specific data formats, so that I can work more efficiently with JSON, JWT tokens, and color codes.

#### Acceptance Criteria

1. WHEN clipboard content is valid JSON THEN the GhostCopy System SHALL display a Prettify button that formats the JSON with proper indentation
2. WHEN clipboard content is a JWT token THEN the GhostCopy System SHALL decode and display the token payload including expiration date and user ID
3. WHEN clipboard content contains a hex color code THEN the GhostCopy System SHALL display a color preview square next to the text
4. WHEN a user activates the Prettify function THEN the GhostCopy System SHALL replace the text field content with the formatted JSON
5. WHEN the GhostCopy System parses JSON for prettification THEN the GhostCopy System SHALL preserve the original data structure exactly
6. WHEN the GhostCopy System formats JSON THEN the GhostCopy System SHALL produce output that parses back to an equivalent data structure

### Requirement 8: Mobile Bidirectional Sync

**User Story:** As a mobile user, I want to both receive clipboard items from desktop and send clipboard items back to desktop, so that I can seamlessly share text in both directions.

#### Acceptance Criteria

1. WHEN a new clipboard item is synced from another device THEN the GhostCopy System SHALL send a push notification to the user's mobile devices
2. WHEN a user taps the push notification THEN the GhostCopy System SHALL open the app and automatically copy the item to the local clipboard
3. WHEN the item is auto-copied THEN the GhostCopy System SHALL display a "Copied!" toast and minimize the application
4. WHEN user has the widget on device THEN the GhostCopy System SHALL display the 5 most recent clips in a scrollable list
5. WHEN a new clip is received THEN the GhostCopy System SHALL update both the app and the home screen widget
6. WHEN a user pastes content into the mobile app send field THEN the GhostCopy System SHALL display a Send button to upload the content
7. WHEN a user taps the Send button THEN the GhostCopy System SHALL send the pasted content to Supabase with device_type as "android" or "ios"
8. WHEN the mobile app opens THEN the GhostCopy System SHALL display a prominent paste area for quick sending

### Requirement 11: Desktop Auto-Receive

**User Story:** As a desktop user, I want clipboard items sent from my mobile devices to automatically appear in my clipboard, so that I can paste them immediately without manual action.

#### Acceptance Criteria

1. WHEN a desktop device receives a clipboard item from another device via Realtime THEN the GhostCopy System SHALL automatically copy the content to the system clipboard
2. WHEN auto-copying to desktop clipboard THEN the GhostCopy System SHALL display a subtle toast notification confirming the copy
3. WHILE Game Mode is active THEN the GhostCopy System SHALL still auto-copy to clipboard but suppress the toast notification
4. WHEN multiple items are received in quick succession THEN the GhostCopy System SHALL copy only the most recent item to avoid clipboard thrashing

### Requirement 9: User Authentication

**User Story:** As a user, I want my clipboard data to be private and secure, so that only I can access my synchronized items.

#### Acceptance Criteria

1. WHEN a user launches the GhostCopy System for the first time THEN the GhostCopy System SHALL require authentication before enabling synchronization
2. WHEN storing clipboard items THEN the GhostCopy System SHALL enforce Row Level Security policies based on user ID
3. WHEN querying clipboard history THEN the GhostCopy System SHALL return only items belonging to the authenticated user

### Requirement 10: Auto-Start Integration

**User Story:** As a desktop user, I want the application to start automatically when I log in, so that clipboard sync is always available.

#### Acceptance Criteria

1. WHEN the user enables auto-start THEN the GhostCopy System SHALL register itself to launch at operating system startup
2. WHEN the GhostCopy System auto-starts THEN the GhostCopy System SHALL launch directly into Sleep Mode with no visible window

### Requirement 12: Modern UI Design Language

**User Story:** As a user, I want the application to have a modern, sleek interface similar to Discord or Blip, so that it feels premium and integrates well with my workflow.

#### Acceptance Criteria

1. WHEN displaying any UI element THEN the GhostCopy System SHALL use a dark theme with subtle glassmorphism effects
2. WHEN the Spotlight Window appears THEN the GhostCopy System SHALL animate the entrance with a smooth fade and scale effect
3. WHEN displaying clipboard history THEN the GhostCopy System SHALL show truncated previews for long content with an expand option
4. WHEN a user hovers over interactive elements THEN the GhostCopy System SHALL provide subtle visual feedback with smooth transitions
5. WHEN displaying the Spotlight Window THEN the GhostCopy System SHALL support full keyboard navigation using Tab and arrow keys

### Requirement 13: Settings Configuration

**User Story:** As a user, I want to customize the application settings, so that I can tailor the experience to my preferences.

#### Acceptance Criteria

1. WHEN a user opens Settings THEN the GhostCopy System SHALL display options for hotkey customization, auto-start toggle, and device name
2. WHEN a user changes the global hotkey THEN the GhostCopy System SHALL immediately register the new hotkey combination
3. WHEN a user updates the device name THEN the GhostCopy System SHALL use the new name for all future clipboard items
