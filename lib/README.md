# GhostCopy Library Structure

This document describes the organization of the GhostCopy codebase.

## Directory Structure

```
lib/
├── models/              # Data models
│   ├── app_state.dart          # Application state model
│   └── clipboard_item.dart     # Clipboard item model with JSON serialization
│
├── repositories/        # Data access layer
│   └── clipboard_repository.dart   # Interface for clipboard data operations
│
├── services/           # Business logic and system integrations
│   ├── auto_receive_service.dart   # Desktop auto-receive functionality
│   ├── game_mode_service.dart      # Game Mode notification management
│   ├── hotkey_service.dart         # Global hotkey registration
│   ├── lifecycle_controller.dart   # Sleep Mode and resource management
│   ├── mobile_send_service.dart    # Mobile clipboard sending
│   ├── transformer_service.dart    # Smart content detection and transformation
│   ├── tray_service.dart           # System tray management
│   └── window_service.dart         # Window lifecycle management
│
├── ui/                 # User interface
│   ├── theme/
│   │   ├── colors.dart             # GhostCopy color palette
│   │   └── typography.dart         # Typography styles
│   ├── widgets/                    # Reusable UI components
│   └── screens/                    # Full screen views
│
└── main.dart           # Application entry point
```

## Service Interfaces

All services are defined as abstract interfaces following the pattern `IServiceName`. This enables:
- Easy testing with mock implementations
- Dependency injection
- Platform-specific implementations
- Clear separation of concerns

### Core Services

1. **IWindowService** - Manages the invisible window and Spotlight popup
2. **IHotkeyService** - Handles global keyboard shortcuts
3. **ITrayService** - Controls system tray icon and menu
4. **ILifecycleController** - Manages Sleep Mode and pausable resources
5. **ITransformerService** - Detects and transforms content (JSON, JWT, hex colors)
6. **IGameModeService** - Queues notifications during full-screen apps
7. **IAutoReceiveService** - Auto-copies received items to desktop clipboard
8. **IMobileSendService** - Handles mobile paste-to-send flow

### Data Access

- **IClipboardRepository** - Supabase operations for clipboard items

## Models

### ClipboardItem
Represents a synchronized clipboard item with:
- User ID for privacy
- Device metadata (name, type)
- Content and timestamps
- JSON serialization for Supabase

### AppState
Tracks overall application state:
- Sleep Mode status
- Game Mode status
- Spotlight visibility
- Clipboard history
- Current item and detected content type

## Design Principles

1. **Service-Based Architecture** - All features implemented as services
2. **Interface Segregation** - Abstract interfaces for all services
3. **Sleep Mode** - Pausable resources for zero-CPU when hidden
4. **Bidirectional Sync** - Desktop and mobile can both send and receive
5. **Type Safety** - Strong typing with Dart 3.x features

## Next Steps

Concrete implementations of these interfaces will be created in subsequent tasks according to the implementation plan in `.kiro/specs/ghostcopy/tasks.md`.
