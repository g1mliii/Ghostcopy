# AGENTS.md

Guide for coding agents working in the GhostCopy Flutter codebase.

## Build & Test Commands

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

# Run all tests
flutter test

# Run single test file
flutter test test/widget_test.dart

# Analyze code (enforces linting rules)
flutter analyze

# Format code
dart format lib test
```

## Code Style Guidelines

### Imports

**Order** (enforced by `directives_ordering` rule):
1. Dart SDK imports (`dart:*`)
2. Flutter imports (`package:flutter/*`)
3. Third-party packages (`package:*`)
4. Relative imports (`../`, `./`)

**Rules**:
- Use single quotes: `import 'package:flutter/material.dart';`
- Alphabetize within each group
- Separate groups with blank lines
- Use `export` directive to re-export implementations from abstract interfaces

**Example**:
```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/clipboard_item.dart';
import '../repositories/clipboard_repository.dart';
import 'auth_service.dart';
```

### Formatting

- **Strings**: Always use single quotes (`'text'`)
- **Trailing commas**: Required for all function/method calls and parameter lists (`require_trailing_commas`)
- **Line endings**: Must end with newline (`eol_at_end_of_file`)
- **Return types**: Always declare explicit return types (`always_declare_return_types`)
- **Type annotations**: Required on all public APIs (`type_annotate_public_apis`)

### Types & Variables

- **Strict typing**: Enabled (`strict-casts`, `strict-inference`, `strict-raw-types`)
- **Local variables**: Omit type annotations, use `final` wherever possible (`omit_local_variable_types`, `prefer_final_locals`)
- **Late variables**: Use `late` for private fields/variables (`use_late_for_private_fields_and_variables`)
- **Avoid dynamic**: Never use `dynamic` or make dynamic calls (`avoid_dynamic_calls`)

**Example**:
```dart
// Good
final userId = _client.auth.currentUser?.id;
late final StreamSubscription<AuthState> _authStateSubscription;

// Bad
String userId = _client.auth.currentUser?.id;
var userId = _client.auth.currentUser?.id; // when obvious type
```

### Naming Conventions

- **Classes**: PascalCase (`ClipboardItem`, `AuthService`)
- **Files**: snake_case (`clipboard_item.dart`, `auth_service.dart`)
- **Variables/functions**: camelCase (`currentUser`, `signInWithEmail`)
- **Private members**: Prefix with underscore (`_client`, `_initialized`)
- **Constants**: lowerCamelCase with `const` (`const _supabaseUrl = '...'`)
- **Enums**: PascalCase enum, camelCase values (`ContentType.imagePng`)

### Architecture Patterns

**Service-Based Architecture**:
- Abstract interface in `lib/services/` (e.g., `IAuthService`)
- Concrete implementation in `lib/services/impl/` (e.g., `AuthService`)
- Use constructor injection for dependencies
- Export implementation from abstract file: `export 'impl/auth_service.dart';`

**Example**:
```dart
// lib/services/auth_service.dart
abstract class IAuthService {
  Future<void> initialize();
  User? get currentUser;
}
export 'impl/auth_service.dart';

// lib/services/impl/auth_service.dart
class AuthService implements IAuthService {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;
  
  final SupabaseClient _client;
  
  @override
  Future<void> initialize() async { /* ... */ }
}
```

### Error Handling

**Exception hierarchy** (see `lib/models/exceptions.dart`):
- `RepositoryException` - Base exception
- `NetworkException` - Connectivity issues
- `ValidationException` - Invalid input, file too large
- `RepositoryStorageException` - Upload/storage failures
- `SecurityException` - Auth/encryption errors

**Rules**:
- Always catch specific exceptions (`avoid_catches_without_on_clauses`)
- Never catch `Error` types, only `Exception` (`avoid_catching_errors`)
- Only throw `Exception` types, not `Error` (`only_throw_errors`)
- Rethrow typed exceptions, wrap unknown exceptions

**Example**:
```dart
try {
  await _client.auth.signInWithPassword(email: email, password: password);
} on AuthException catch (e) {
  debugPrint('[AuthService] Sign in failed: ${e.message}');
  rethrow;
} catch (e) {
  throw RepositoryException('Failed to sign in: $e');
}
```

### Async/Await

- Avoid `async` for void functions (`avoid_void_async`)
- Don't await in return statements when unnecessary (`unnecessary_await_in_return`)
- Always await futures or mark as unawaited (`unawaited_futures`)
- Cancel stream subscriptions in dispose (`cancel_subscriptions`)

### Comments & Documentation

- Use `///` for public API documentation (before class/method)
- Use `//` for implementation comments
- Document all parameters with `[paramName]` in doc comments
- Include usage examples for complex APIs

**Example**:
```dart
/// Insert a new clipboard item and return it with generated ID
Future<ClipboardItem> insert(ClipboardItem item);

/// Upgrade anonymous user to email/password account
/// Uses Supabase's updateUser() to preserve user_id and clipboard data
/// Throws exception if email already exists
/// [captchaToken] Required if captcha is enabled in Supabase
Future<UserResponse> upgradeWithEmail(
  String email,
  String password, {
  String? captchaToken,
});
```

### Widget Best Practices

- Use `const` constructors wherever possible (reduces rebuilds)
- Prefer `final` for widget properties
- Use named parameters for clarity
- Extract reusable widgets to separate files in `lib/ui/widgets/`

## Performance Optimizations

GhostCopy employs aggressive performance optimizations to maintain 60fps with zero dropped frames.

### Compute Isolates

Heavy operations run on background threads via `compute()` to prevent UI blocking:

**Services using isolates:**
- **EncryptionService**: PBKDF2 key derivation (100k iterations), AES-256-GCM encryption/decryption
  - Threshold: >5KB content for encryption, >7KB for decryption
  - Files: `lib/services/impl/encryption_service.dart`
- **TransformerService**: JSON parsing/prettification, JWT decoding, content detection
  - Threshold: >10KB content
  - Files: `lib/services/impl/transformer_service.dart`
- **CachedClipboardImage**: Image decoding and resizing
  - Threshold: >100KB images
  - Files: `lib/ui/widgets/cached_clipboard_image.dart`
- **ClipboardRepository**: Large response parsing from Supabase
  - Threshold: >20 items
  - Files: `lib/repositories/impl/clipboard_repository.dart`

**Rules for compute isolates:**
- Use `compute()` for operations taking >16ms (one frame at 60fps)
- Always provide top-level or static functions to `compute()`
- Create parameter classes for complex inputs (see `_EncryptParams`, `_DetectionParams`)
- Add thresholds to avoid isolate overhead for small operations

**Example:**
```dart
// Parameter class
class _ProcessParams {
  const _ProcessParams(this.input);
  final String input;
}

// Top-level function (required by compute())
String _processInIsolate(_ProcessParams params) {
  // Heavy computation here
  return result;
}

// In your service
Future<String> process(String input) async {
  // Small content: process synchronously
  if (input.length < 10240) {
    return _processInIsolate(_ProcessParams(input));
  }
  
  // Large content: use isolate
  return compute(_processInIsolate, _ProcessParams(input));
}
```

### RepaintBoundary Usage

Use `RepaintBoundary` to isolate independently changing widgets and reduce repaints:

**Where RepaintBoundary is used:**
- Settings panel: Each toggle/slider/section wrapped independently
  - Files: `lib/ui/widgets/settings_panel.dart`
- Device panel: Each list item isolated with ValueKey
  - Files: `lib/ui/widgets/device_panel.dart`
- Transformation previews: JSON/JWT/color preview widgets
  - Files: `lib/ui/screens/spotlight_screen.dart`
- Setting toggles: Generic `_buildSettingToggle` has built-in boundary
  - Files: `lib/ui/widgets/settings_panel.dart`

**When to use:**
- Widget has its own animation controller
- Widget changes independently of siblings/parent
- Widget contains heavy rendering (CustomPaint, large images)
- List items in scrollable views

**When NOT to use:**
- Static widgets (no benefit, only overhead)
- Widgets that always rebuild together
- Very simple widgets (<100 render objects)

**Example:**
```dart
// In ListView.builder
itemBuilder: (context, index) {
  return RepaintBoundary(
    key: ValueKey(items[index].id), // Unique key required
    child: ItemWidget(item: items[index]),
  );
}
```

### Memory Management

**Cache Strategies:**
- **LRU eviction**: Remove oldest entries when size limit reached
- **Lifecycle cleanup**: Clear caches on app background (mobile)
- **Threshold-based**: Avoid caching very small or very large content
- **Explicit disposal**: Always dispose controllers in widget.dispose()

**Image Caching:**
- 3-tier: CDN → memory → storage API fallback
- Memory cache: 2x display size (`memCacheWidth: width * 2`)
- Disk cache: Max 1000x1000 for thumbnails
- Auto-cleanup: Clear `_fallbackImageBytes` in dispose()
- Files: `lib/ui/widgets/cached_clipboard_image.dart`

**Decryption Cache** (mobile only):
- Maps `item.id → decrypted content`
- LRU eviction when size > 50 items
- Cleared on app background
- Files: `lib/ui/screens/mobile_main_screen.dart`

**Memory Pressure Handling** (mobile only):
Flutter provides built-in memory pressure monitoring via `WidgetsBindingObserver.didHaveMemoryPressure()`. This is called by iOS/Android when the system detects low memory conditions.

**Implementation:**
```dart
class _MyScreenState extends State<MyScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    debugPrint('[MyScreen] ⚠️ System memory pressure - clearing caches');
    
    // Clear all caches aggressively
    _contentCache.clear();
    imageCache.clear();
    imageCache.clearLiveImages();
    
    // Trim data to essentials
    if (mounted) {
      setState(() {
        _items = _items.take(10).toList();
      });
    }
  }
}
```

**When to use:**
- Mobile apps with large data sets (clipboard history, images)
- Apps with heavy caching strategies
- Prevents OS from terminating app due to memory usage

Files: `lib/ui/screens/mobile_main_screen.dart`

### Animation Lifecycle

**Tray Mode (Zero-CPU):**
- All `AnimationController`s pause when window hidden
- Realtime connections switch to polling mode
- Streams paused to conserve quota
- Automatic resume on window show
- Files: `lib/main.dart`, `lib/ui/screens/spotlight_screen.dart`

**Implementation:**
```dart
// Use SingleTickerProviderStateMixin
class _MyWidgetState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  
  @override
  void dispose() {
    _controller.dispose(); // CRITICAL: prevent memory leaks
    super.dispose();
  }
}
```

### Shader Warmup

Precompile common shaders on startup to prevent first-frame jank (desktop only):

```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  final canvas = Canvas(PictureRecorder());
  final paint = Paint();
  canvas.drawRect(Rect.largest, paint);  // Rectangles
  canvas.drawRRect(RRect.fromLTRBR(0, 0, 100, 100, const Radius.circular(8)), paint);  // Rounded corners
  paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);  // Blur effects
  canvas.drawRect(Rect.largest, paint);
});
```

Files: `lib/main.dart` (MyApp.initState)
Eliminates: 50-100ms stutter on first animations

### Icon Pre-caching

Pre-render frequently used Material Icons to eliminate first-frame jank (desktop only):

```dart
void _precacheCommonIcons() {
  final commonIcons = [
    Icons.content_copy,
    Icons.send_rounded,
    Icons.settings_outlined,
    // ... other frequently used icons
  ];
  
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  
  for (final icon in commonIcons) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          fontSize: 24,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset.zero);
  }
  recorder.endRecording();
}
```

**Implementation:**
- Call in `WidgetsBinding.instance.addPostFrameCallback()` after shader warmup
- Forces Flutter to load and cache icon font glyphs
- Prevents stuttering when icons first appear in UI

Files: `lib/main.dart` (_MyAppState._precacheCommonIcons)
Eliminates: 10-30ms stutter on first icon render

### Expected Performance Improvements

| Optimization | Before | After | Improvement |
|-------------|--------|-------|-------------|
| Large JSON paste (100KB) | 150-300ms lag | < 16ms | **90% faster** |
| Image scroll (100+ images) | 45-55 FPS | 58-60 FPS | **10% smoother** |
| Encryption operation | 100-200ms freeze | 0ms freeze | **100% non-blocking** |
| Settings toggle | Repaints 50 widgets | Repaints 1 widget | **98% fewer repaints** |
| Tray mode CPU (desktop) | 2-5% | < 0.1% | **95% reduction** |

## Testing

- **Framework**: `flutter_test` + `glados` for property-based testing
- **Mocking**: Use `mocktail` package
- Property tests: Minimum 100 iterations
- Tag property tests: `**Feature: ghostcopy, Property N: description**`

## Key Architectural Notes

- **Sleep Mode**: Pause all `TickerProvider`s and non-essential streams when Spotlight hidden (zero-CPU)
- **Bidirectional Sync**: Desktop ↔ Mobile via Supabase Realtime
- **Auth Flow**: Anonymous by default, upgrade to email/password or Google OAuth
- **Content Types**: Text, images, files, rich text (HTML/Markdown)
- **Encryption**: Optional user passphrase for end-to-end encryption

## Platform Detection

```dart
import 'dart:io';

if (Platform.isWindows || Platform.isMacOS) {
  // Desktop logic
}
if (Platform.isIOS || Platform.isAndroid) {
  // Mobile logic
}
```

## Debugging

- Use `debugPrint()` instead of `print()`
- Prefix debug logs with service name: `debugPrint('[AuthService] Message')`
- Use emoji prefixes for visibility: `🚀 Starting`, `✅ Success`, `❌ Error`
