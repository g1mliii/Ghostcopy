# Flutter Development Patterns

## Performance Optimization

### Use const Widgets
Always use `const` constructors where possible to reduce rebuilds:
```dart
// Good
const SizedBox(height: 16),
const Icon(Icons.send),

// Bad
SizedBox(height: 16),
Icon(Icons.send),
```

### Avoid Unnecessary Rebuilds
- Use `const` widgets
- Split large widgets into smaller stateless widgets
- Use `ValueListenableBuilder` or `StreamBuilder` for reactive updates
- Avoid calling `setState` for unrelated state changes

### Sleep Mode Pattern
Implement `Pausable` interface for any resource that should stop during sleep:
```dart
abstract class Pausable {
  void pause();
  void resume();
}

class MyAnimationController implements Pausable {
  late AnimationController _controller;
  
  @override
  void pause() => _controller.stop();
  
  @override
  void resume() => _controller.forward();
}
```

## State Management

### Simple State
For simple local state, use `StatefulWidget` with `setState`.

### Service State
Services expose streams for reactive updates:
```dart
class GameModeService {
  final _isActiveController = StreamController<bool>.broadcast();
  Stream<bool> get isActiveStream => _isActiveController.stream;
  
  bool _isActive = false;
  bool get isActive => _isActive;
  
  void toggle() {
    _isActive = !_isActive;
    _isActiveController.add(_isActive);
  }
}
```

## Error Handling

### Graceful Degradation
Always handle errors gracefully without crashing:
```dart
ContentType detectType(String content) {
  try {
    json.decode(content);
    return ContentType.json;
  } catch (_) {
    // Not JSON, try next format
  }
  
  if (_isJwt(content)) return ContentType.jwt;
  if (_hasHexColor(content)) return ContentType.hexColor;
  
  return ContentType.plainText;
}
```

### User Feedback
Show toast notifications for errors, don't fail silently:
```dart
try {
  await clipboardRepository.insert(item);
  showToast('Sent!', type: ToastType.success);
} catch (e) {
  showToast('Failed to send. Check your connection.', type: ToastType.error);
}
```

## Animation Patterns

### Spotlight Window Animation
```dart
class SpotlightWindow extends StatefulWidget {
  @override
  State<SpotlightWindow> createState() => _SpotlightWindowState();
}

class _SpotlightWindowState extends State<SpotlightWindow> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: _buildContent(),
      ),
    );
  }
}
```

### Staggered List Animation
```dart
class HistoryList extends StatelessWidget {
  final List<ClipboardItem> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, index) {
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: Duration(milliseconds: 200 + (index * 50)),
          builder: (context, value, child) {
            return Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 20 * (1 - value)),
                child: child,
              ),
            );
          },
          child: HistoryItemCard(item: items[index]),
        );
      },
    );
  }
}
```

## Testing Patterns

### Property-Based Test Structure
```dart
import 'package:glados/glados.dart';

void main() {
  // **Feature: ghostcopy, Property 16: JSON Round-Trip**
  Glados<Map<String, dynamic>>().test(
    'prettifying then parsing JSON preserves structure',
    (jsonMap) {
      final original = json.encode(jsonMap);
      final prettified = transformerService.prettifyJson(original);
      final reparsed = json.decode(prettified);
      
      expect(reparsed, equals(jsonMap));
    },
  );
}
```

### Custom Generators
```dart
extension ClipboardItemGenerator on Any {
  Generator<ClipboardItem> get clipboardItem => any.combine2(
    any.nonEmptyString,
    any.choose(['windows', 'macos', 'android', 'ios']),
    (content, deviceType) => ClipboardItem(
      id: any.positiveInt.toString(),
      userId: 'test-user',
      content: content,
      deviceName: 'Test Device',
      deviceType: deviceType,
      isPublic: false,
      createdAt: DateTime.now(),
    ),
  );
}
```

## Keyboard Navigation

### Focus Management
```dart
class SpotlightWindow extends StatefulWidget {
  @override
  State<SpotlightWindow> createState() => _SpotlightWindowState();
}

class _SpotlightWindowState extends State<SpotlightWindow> {
  final _textFocusNode = FocusNode();
  final _sendFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Auto-focus text field when window appears
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _textFocusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      onKeyEvent: (event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _close();
          } else if (event.logicalKey == LogicalKeyboardKey.enter) {
            _send();
          }
        }
      },
      child: Column(
        children: [
          TextField(focusNode: _textFocusNode),
          ElevatedButton(focusNode: _sendFocusNode, onPressed: _send),
        ],
      ),
    );
  }
}
```
