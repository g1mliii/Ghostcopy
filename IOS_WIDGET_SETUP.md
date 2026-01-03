# iOS Widget Extension Setup Guide

This guide explains how to complete the iOS widget implementation in Xcode.

## What's Already Done

✅ All Swift source files created:
- `ios/Runner/WidgetDataManager.swift` - App Group data bridge
- `ios/ClipboardWidget/ClipboardWidgetProvider.swift` - TimelineProvider
- `ios/ClipboardWidget/ClipboardWidgetView.swift` - SwiftUI UI
- `ios/ClipboardWidget/RefreshWidgetIntent.swift` - App Intents (Refresh & Copy)
- `ios/ClipboardWidget/ClipboardWidget.swift` - Widget entry point
- Entitlements files created for both targets

✅ AppDelegate.swift modified:
- Widget method channel setup
- Deep link handling for `ghostcopy://copy/`
- FCM notification widget updates
- Supabase credentials storage

## Xcode Setup Steps (Manual)

### Step 1: Create Widget Extension Target

1. Open `ios/Runner.xcworkspace` in Xcode (NOT the `.xcodeproj`)
2. Select the **Runner** project in the left sidebar
3. Go to **File** → **New** → **Target**
4. Select **"Widget Extension"** template
5. Set these values:
   - **Product Name**: `ClipboardWidget`
   - **Team**: Your team ID
   - **Organization**: GhostCopy
   - **Language**: Swift
   - ☐ **Include configuration intent** (leave unchecked)
6. Click **Finish**

Xcode will prompt to create a bridging header. Click **Create Bridging Header**.

### Step 2: Copy Swift Files to Widget Target

Once the target is created, Xcode should have created these folders:
```
ios/ClipboardWidget/
  ClipboardWidget.swift  (template file - REPLACE)
  ...
```

1. **Delete** all files Xcode created in `ios/ClipboardWidget/`
2. **Copy** the Swift files we created into `ios/ClipboardWidget/`:
   - `ClipboardWidget.swift` (main entry point)
   - `ClipboardWidgetProvider.swift` (TimelineProvider)
   - `ClipboardWidgetView.swift` (SwiftUI view)
   - `RefreshWidgetIntent.swift` (App Intents)

3. In Xcode, right-click `ClipboardWidget` target → **Add Files to ClipboardWidget**
4. Select the 4 Swift files above
5. Make sure ✅ **"Copy items if needed"** is checked
6. Make sure ☑️ **ClipboardWidget** is selected as target (NOT Runner)

### Step 3: Add Info.plist to Widget Target

The widget target needs its own `Info.plist`:

1. Right-click the `ios/ClipboardWidget` folder → New → File
2. Select **Property List**
3. Name it `Info.plist`
4. Set these values in the plist:
   ```
   CFBundleDisplayName = ClipboardWidget
   CFBundleExecutable = $(EXECUTABLE_NAME)
   CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)
   CFBundleInfoDictionaryVersion = 6.0
   CFBundleName = $(PRODUCT_NAME)
   CFBundlePackageType = APPL
   CFBundleShortVersionString = 1.0.0
   CFBundleVersion = 1
   MinimumOSVersion = 15.0
   NSExtension:
     NSExtensionPointIdentifier = com.apple.widgetkit-extension
   ```

Or manually:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>ClipboardWidget</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$(FLUTTER_BUILD_NAME)</string>
	<key>CFBundleVersion</key>
	<string>$(FLUTTER_BUILD_NUMBER)</string>
	<key>MinimumOSVersion</key>
	<string>15.0</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
```

### Step 4: Configure Build Settings

1. Select **ClipboardWidget** target
2. Go to **Build Settings**
3. Search for "Entitlements"
4. Set **Code Signing Entitlements** to:
   ```
   ios/ClipboardWidget/ClipboardWidget.entitlements
   ```

5. Search for "Product Bundle Identifier"
6. Set it to:
   ```
   $(PRODUCT_BUNDLE_IDENTIFIER).ClipboardWidget
   ```

### Step 5: Configure Runner Target Entitlements

1. Select **Runner** target
2. Go to **Build Settings**
3. Search for "Entitlements"
4. Set **Code Signing Entitlements** to:
   ```
   ios/Runner/Runner.entitlements
   ```

### Step 6: Add Localizable.strings (Optional)

Widget bundles sometimes need localization files.

1. Right-click `ios/ClipboardWidget` → New → File
2. Select **Strings File**
3. Name it `Localizable.strings`
4. Add this content:
   ```
   /* Empty - using hardcoded strings in code */
   ```

### Step 7: Verify Build Phases

1. Select **ClipboardWidget** target
2. Go to **Build Phases**
3. Verify **Compile Sources** includes:
   - `ClipboardWidget.swift`
   - `ClipboardWidgetProvider.swift`
   - `ClipboardWidgetView.swift`
   - `RefreshWidgetIntent.swift`

4. Verify **Copy Bundle Resources** includes:
   - `ClipboardWidget.entitlements`
   - `Info.plist` (widget target)

### Step 8: Build & Test

1. Select **ClipboardWidget** scheme from the top dropdown
2. Select **iPhone 15 Pro** simulator
3. Press **Cmd+B** to build
4. If build succeeds, select **Runner** scheme and build again
5. Run the app: **Cmd+R**
6. Long-press home screen → "Edit Home Screen" → Search "Clipboard" → Add widget

## Memory Leak Prevention Features Implemented

✅ **WidgetDataManager**
- Weak references for delegates
- Proper UserDefaults cleanup
- Singleton pattern with safe initialization

✅ **ClipboardWidgetProvider**
- Lightweight data loading (no heavy parsing)
- Manual refresh only (no background polling)
- Never timeline policy (zero resource drain)

✅ **RefreshWidgetIntent**
- URLSession with proper timeout configuration
- No retained URLSession objects
- Proper error handling and cleanup

✅ **AppDelegate Widget Updates**
- Weak self in escaping closures
- Proper notification cleanup
- No circular references

## Troubleshooting

### Widget doesn't appear
- Verify App Group identifier matches: `group.com.ghostcopy.app`
- Check entitlements files are signed
- Rebuild both targets
- Restart simulator: `xcrun simctl erase all`

### Widget crashes
- Check Console.app for widget process logs
- Verify Info.plist is complete
- Check that Swift files are in ClipboardWidget target (not Runner)

### Data not syncing
- Verify WidgetDataManager uses correct UserDefaults suite name
- Check that App Group is enabled in both targets
- Verify AppDelegate calls `WidgetCenter.reloadAllTimelines()`

### Entitlements issues
- Compare with existing entitlements in Runner target
- Verify Team ID matches across all targets
- Re-sign after modifying entitlements

## FCM Integration Notes

When you receive APNs certificates and credentials:

1. **AppDelegate.swift** already handles FCM notifications
2. **updateWidgetForFCMNotification()** updates widget on notification arrival
3. **RefreshWidgetIntent** can fetch fresh data from Supabase
4. Simply update these files with final APNs setup:
   - `GoogleService-Info.plist` (add APNs certificate)
   - Firebase project console (APNs configuration)
   - Run `flutter pub get` to update Firebase plugins

No code changes needed - the infrastructure is ready!

## Next Steps

1. Complete the 8 Xcode setup steps above
2. Test widget on simulator:
   - Add widget to home screen
   - Tap items to copy content
   - Tap refresh button
3. Test on physical device:
   - Build with real Apple ID
   - Test FCM notifications (when credentials available)
   - Monitor memory usage in Xcode Profiler

## Architecture Overview

```
App (Flutter)
    ↓ (method channel)
AppDelegate.swift
    ↓ (stores credentials, listens for updates)
WidgetDataManager.swift (shared via App Group)
    ↓ (reads from UserDefaults)
ClipboardWidget (Extension)
    ↓ (TimelineProvider loads data)
ClipboardWidgetProvider.swift
    ↓ (displays via SwiftUI)
ClipboardWidgetView.swift
```

## Key Files

| File | Purpose | Location |
|------|---------|----------|
| WidgetDataManager.swift | App Group bridge | `ios/Runner/` |
| ClipboardWidget.swift | Widget entry point | `ios/ClipboardWidget/` |
| ClipboardWidgetProvider.swift | Timeline provider | `ios/ClipboardWidget/` |
| ClipboardWidgetView.swift | UI (SwiftUI) | `ios/ClipboardWidget/` |
| RefreshWidgetIntent.swift | App Intents | `ios/ClipboardWidget/` |
| AppDelegate.swift | FCM + deep links | `ios/Runner/` (modified) |
| Runner.entitlements | App Group (main app) | `ios/Runner/` |
| ClipboardWidget.entitlements | App Group (widget) | `ios/ClipboardWidget/` |

---

**Status**: Phase 3 iOS Widget - Code Complete ✅
**Next**: Complete Xcode setup & test on simulator/device
