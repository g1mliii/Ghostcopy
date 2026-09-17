# iOS Widget Extension

The widget extension is wired into `ios/Runner.xcodeproj` and builds as part of
the normal `Runner` scheme. There are no manual Xcode steps left - this file
used to be a to-do list for creating the target by hand, and none of it is
needed any more.

## Layout

| File | Purpose | Target |
|------|---------|--------|
| `ios/Runner/WidgetDataManager.swift` | App Group bridge | Runner **and** ClipboardWidget |
| `ios/ClipboardWidget/ClipboardWidget.swift` | `WidgetBundle` entry point | ClipboardWidget |
| `ios/ClipboardWidget/ClipboardWidgetProvider.swift` | `TimelineProvider` | ClipboardWidget |
| `ios/ClipboardWidget/ClipboardWidgetView.swift` | SwiftUI UI | ClipboardWidget |
| `ios/ClipboardWidget/RefreshWidgetIntent.swift` | Refresh + Copy App Intents | ClipboardWidget |
| `ios/ClipboardWidget/Info.plist` | `com.apple.widgetkit-extension` | ClipboardWidget |
| `ios/ClipboardWidget/ClipboardWidget.entitlements` | App Group | ClipboardWidget |

`WidgetDataManager.swift` is deliberately compiled into both targets: the app
writes the clipboard rows, the widget process reads them, and they meet in the
App Group container rather than through a shared framework.

## Target configuration

- **Bundle id**: `com.ghostcopy.ghostcopy.widget`.
  Not `...ClipboardWidget` - that identifier is already taken in the developer
  portal and automatic signing refuses to register it ("cannot be registered to
  your development team because it is not available").
- **Deployment target**: iOS 17.0, above the app's 16.0. The widget needs
  `Button(intent:)`, `containerBackground(for: .widget)` and App Intents, all
  of which are iOS 17.
- **App Group**: `group.com.ghostcopy.app`, on both targets. Both signed
  entitlements must list it or the widget reads an empty container.
- **Base xcconfig**: `Flutter/Generated.xcconfig` - for `FLUTTER_BUILD_NAME` /
  `FLUTTER_BUILD_NUMBER` only. Deliberately *not* `Flutter/Debug.xcconfig`,
  which pulls in `Pods-Runner` and would link the app's pods into the widget.
- Embedded into the app by an **Embed Foundation Extensions** phase placed
  after Embed Frameworks, so the extension is signed before Flutter's Thin
  Binary step runs.

## Widget sizes

`ClipboardWidgetView` reads `@Environment(\.widgetFamily)` and sizes itself:
small and medium show 2 rows, large shows 5. This matters - a systemMedium
widget is roughly 155pt tall, and rendering five 64pt rows plus a header
overflowed it badly enough to clip the header off the top.

## Tap behaviour

- **Text** rows run `CopyToClipboardIntent` inside the widget process and write
  the pasteboard without leaving the home screen.
- **File and image** rows are a `Link` to `ghostcopy://share/<id>`, handled by
  `SceneDelegate`. The widget holds only a preview and a thumbnail, never the
  payload, and an encrypted clip still needs the key - so these have to go
  through the app.

## Thumbnails

`WidgetService._getWidgetCacheDir()` puts thumbnails in the App Group
container on iOS, via the `getAppGroupContainerPath` method channel call. The
widget runs in its own sandbox and cannot read the app's own cache directory,
so anything written there is invisible to it.

## Building

```bash
flutter build ios --debug
```

Or straight from Xcode against the `Runner` scheme; the widget builds as a
dependency. To add it on device: long-press the home screen, tap the
customize button top-left, **Add Widget**, then search for GhostCopy.

WidgetKit caches the extension aggressively and the timeline policy is
`.never`, so after reinstalling you may need to remove and re-add the widget
(or reboot the device) to see code changes.
