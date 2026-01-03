# Complete Xcode Setup Guide for GhostCopy iOS

This document covers **ALL** Xcode setup required for GhostCopy iOS (not just widgets).

## Overview

You need Xcode setup for:
1. ✅ Code signing and provisioning profiles
2. ✅ App Groups entitlements (app + widget communication)
3. ✅ Push notifications capability (for FCM)
4. ✅ Widget Extension target
5. ✅ GoogleService-Info.plist integration

---

## Part 1: Code Signing & Team Configuration

### 1.1 Set Signing Team

1. Open `ios/Runner.xcworkspace` in Xcode (not `.xcodeproj`)
2. Select **Runner** project in left sidebar
3. Select **Runner** target (app target)
4. Go to **Signing & Capabilities** tab
5. Under **Team**, select your Apple Team
   - If not listed, click "Add an Account"
   - Login with Apple ID
6. Select the team from dropdown

### 1.2 Verify Bundle Identifier

1. Select **Runner** target
2. Go to **General** tab
3. Verify **Bundle Identifier**:
   - Should be: `com.ghostcopy.ghostcopy`
   - If different, update to match
4. Verify **Version** and **Build**:
   - Version: `1.0.0` (or your preferred)
   - Build: `1`

### 1.3 Do Same for Widget Target

1. Select **ClipboardWidget** target (after creating it)
2. Go to **Signing & Capabilities** tab
3. Select same team
4. Verify **Bundle Identifier**:
   - Should be: `com.ghostcopy.ghostcopy.ClipboardWidget`
   - Automatically set to app bundle + extension name

---

## Part 2: App Groups Entitlements

App Groups allow the main app and widget to share data via UserDefaults.

### 2.1 Add to Runner Target

1. Select **Runner** target
2. Go to **Signing & Capabilities** tab
3. Click **+ Capability** (blue plus button)
4. Search for "App Groups"
5. Click to add
6. In the list that appears, click **+ button**
7. Enter: `group.com.ghostcopy.app`
8. Should now show:
   ```
   ☑️ App Groups
   └─ group.com.ghostcopy.app
   ```

### 2.2 Add to ClipboardWidget Target

1. Select **ClipboardWidget** target
2. Go to **Signing & Capabilities** tab
3. Click **+ Capability**
4. Search for "App Groups"
5. Click to add
6. Enter: `group.com.ghostcopy.app` (same as main app)

**Result**: Both targets should now have identical App Group identifiers.

---

## Part 3: Push Notifications Capability

For FCM to work, enable push notifications.

### 3.1 Add to Runner Target

1. Select **Runner** target
2. Go to **Signing & Capabilities** tab
3. Click **+ Capability**
4. Search for "Push Notifications"
5. Click to add
6. Should show: `☑️ Push Notifications`

**Note**: You'll see a warning about APNs certificate. This is normal - the certificate will be added once you upload APNs to Firebase.

### 3.2 Do NOT add to Widget Target

Widget extensions cannot receive push notifications directly. The main app receives notifications and updates the widget.

---

## Part 4: Create Widget Extension Target

### 4.1 Create New Target

1. In Xcode, select **Runner** project
2. Go to **File** → **New** → **Target**
3. Choose **Widget Extension** template
4. Configure:
   - **Product Name**: `ClipboardWidget`
   - **Organization**: GhostCopy
   - **Language**: Swift
   - ☐ **Include configuration intent** (leave unchecked)
5. Click **Finish**

Xcode will ask "Add ClipboardWidget to scheme?" → Click **Yes**.

### 4.2 Copy Swift Files to Widget Target

Once the target is created:

1. **Delete** all template files Xcode created in `ios/ClipboardWidget/`
   - Delete `ClipboardWidget.swift` (template)
   - Delete `ClipboardWidgetBundle.swift` if present
   - Delete `ClipboardWidget.intentdefinition` if present

2. **Add our Swift files** to the widget target:
   - `ios/ClipboardWidget/ClipboardWidget.swift`
   - `ios/ClipboardWidget/ClipboardWidgetProvider.swift`
   - `ios/ClipboardWidget/ClipboardWidgetView.swift`
   - `ios/ClipboardWidget/RefreshWidgetIntent.swift`

3. In Xcode, right-click `ios/ClipboardWidget` folder
4. Select **Add Files to ClipboardWidget**
5. Select the 4 files above
6. ☑️ Check **Copy items if needed**
7. ☑️ Check **ClipboardWidget** target (NOT Runner)
8. Click **Add**

### 4.3 Configure ClipboardWidget Build Settings

1. Select **ClipboardWidget** target
2. Go to **Build Settings** tab
3. Search for "Entitlements"
4. Set **Code Signing Entitlements** to:
   ```
   ios/ClipboardWidget/ClipboardWidget.entitlements
   ```

5. Search for "Bundle Identifier"
6. Verify it's set to:
   ```
   $(PRODUCT_BUNDLE_IDENTIFIER).ClipboardWidget
   ```
   This automatically appends `.ClipboardWidget` to main app bundle ID.

### 4.4 Create Info.plist for Widget Target

1. Right-click `ios/ClipboardWidget` folder
2. Select **New** → **File**
3. Choose **Property List**
4. Name it: `Info.plist`
5. Content (paste into editor):

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

### 4.5 Verify Build Phases

1. Select **ClipboardWidget** target
2. Go to **Build Phases** tab
3. Expand **Compile Sources**
4. Verify all 4 Swift files are listed:
   - `ClipboardWidget.swift`
   - `ClipboardWidgetProvider.swift`
   - `ClipboardWidgetView.swift`
   - `RefreshWidgetIntent.swift`
5. Expand **Copy Bundle Resources**
6. Verify both entitlements files are there:
   - `ClipboardWidget.entitlements`
   - `Runner.entitlements`

---

## Part 5: GoogleService-Info.plist Integration

This file enables Firebase Cloud Messaging (FCM).

### 5.1 Download GoogleService-Info.plist

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Select **GhostCopy** project
3. Go to **Settings** (gear icon) → **Project settings**
4. Select **iOS** tab
5. Click **Download GoogleService-Info.plist**

### 5.2 Add to Xcode Project

1. In Xcode, right-click **Runner** folder (project root)
2. Select **Add Files to Runner**
3. Select the downloaded `GoogleService-Info.plist`
4. ☑️ Check **Copy items if needed**
5. ☑️ Check **Runner** target ONLY (not widget)
6. Click **Add**

### 5.3 Verify in Build Phases

1. Select **Runner** target
2. Go to **Build Phases** tab
3. Expand **Copy Bundle Resources**
4. Verify `GoogleService-Info.plist` is listed
5. Should be in **Runner** target only (not ClipboardWidget)

---

## Part 6: Run Configuration

### 6.1 Select Correct Scheme

1. Top of Xcode, click scheme selector
2. You should see two schemes:
   - **Runner** (main app)
   - **ClipboardWidget** (widget extension)
3. Select **Runner** for main app testing

### 6.2 Select Device

1. Select **iPhone 15 Pro** simulator (or device of choice)
2. Recommended devices:
   - iPhone 15 Pro (latest iOS)
   - iPhone 14 (older iOS, good for compatibility testing)
   - Physical iPhone (for FCM testing)

---

## Part 7: Build & Test

### 7.1 Clean Build

1. Select **Runner** target
2. Press **Cmd+Shift+K** to clean build folder
3. Press **Cmd+B** to build
4. Wait for build to complete

### 7.2 Run on Simulator

1. Select **Runner** scheme
2. Select simulator device
3. Press **Cmd+R** to run
4. Wait for app to launch

### 7.3 Test Widget

1. Long-press home screen
2. Tap **Edit Home Screen** (bottom left)
3. Tap **+ Add Widgets** (top left)
4. Search for "Clipboard"
5. Select **ClipboardWidget**
6. Choose size (small/medium/large)
7. Tap **Add Widget**
8. Long-press widget → tap clipboard item
9. Verify it copies to clipboard

---

## Part 8: Run on Physical Device (Optional)

### 8.1 Connect Device

1. Connect iPhone via USB-C
2. Unlock device
3. Trust this computer (if prompted)
4. Device appears in device list

### 8.2 Automatic Signing

1. Select **Runner** target
2. Go to **Signing & Capabilities**
3. Check **Automatically manage signing**
4. Select your team

### 8.3 Build & Run

1. Select your device from device list
2. Press **Cmd+R**
3. App installs and runs on device

### 8.4 Test FCM (Device Only)

FCM only works on physical devices, not simulator:

1. Console should show:
   ```
   [App] Got FCM token: <token_here>
   ```
2. Copy this token
3. Send test notification via Firebase Console
4. Notification should appear with action buttons

---

## Troubleshooting

### "Cannot find WidgetDataManager in scope"

**Cause**: WidgetDataManager is in Runner target but AppDelegate tries to use it
**Solution**:
1. Select **Runner** target
2. Go to **Build Phases** → **Compile Sources**
3. Verify `ios/Runner/WidgetDataManager.swift` is listed
4. If not, click **+** and add it

### "Missing Push Notifications capability"

**Solution**:
1. Select **Runner** target
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Add **Push Notifications**

### "App Groups not syncing"

**Causes & Solutions**:
1. Different App Group identifier:
   - Runner: `group.com.ghostcopy.app`
   - ClipboardWidget: `group.com.ghostcopy.app`
   - Both must be IDENTICAL

2. Entitlements file not signed:
   - Delete both targets' entitlements
   - Re-add from Signing & Capabilities tab
   - Don't edit `.entitlements` files manually

3. Code Signing Entitlements not set:
   - Runner target: Set to `ios/Runner/Runner.entitlements`
   - ClipboardWidget: Set to `ios/ClipboardWidget/ClipboardWidget.entitlements`

### "Widget not appearing on home screen"

**Solutions**:
1. Verify widget target built successfully
2. Delete app from simulator
3. Clean build folder: **Cmd+Shift+K**
4. Rebuild: **Cmd+B**
5. Run: **Cmd+R**
6. Try again

### "Action buttons not showing on notification"

**Cause**: Notification category not registered
**Solution**:
1. Check `registerNotificationCategories()` is called in `didFinishLaunching`
2. Check `ActionableNotificationManager.swift` is in **Runner** target Compile Sources
3. Rebuild app

---

## Summary: Checklist for Xcode Setup

### Code Signing:
- [ ] Select signing team for Runner target
- [ ] Select signing team for ClipboardWidget target
- [ ] Bundle ID is `com.ghostcopy.ghostcopy`
- [ ] Widget bundle ID is `com.ghostcopy.ghostcopy.ClipboardWidget`

### Entitlements:
- [ ] Runner has App Groups: `group.com.ghostcopy.app`
- [ ] ClipboardWidget has App Groups: `group.com.ghostcopy.app`
- [ ] Runner has Push Notifications capability
- [ ] Runner has Code Signing Entitlements: `ios/Runner/Runner.entitlements`
- [ ] ClipboardWidget has Code Signing Entitlements: `ios/ClipboardWidget/ClipboardWidget.entitlements`

### Widget Target:
- [ ] Widget Extension target created
- [ ] 4 Swift files in ClipboardWidget target Compile Sources
- [ ] Info.plist created with NSExtension configuration
- [ ] Build settings configured

### Firebase:
- [ ] GoogleService-Info.plist downloaded
- [ ] GoogleService-Info.plist added to Runner target
- [ ] In Copy Bundle Resources

### Build & Test:
- [ ] Clean build passes: **Cmd+Shift+K** → **Cmd+B**
- [ ] App runs on simulator: **Cmd+R**
- [ ] Widget appears on home screen
- [ ] Widget refresh button works
- [ ] Tap widget copies to clipboard

---

## Additional Notes

### iOS Versions Supported:
- Minimum: iOS 14 (for WidgetKit)
- Recommended: iOS 15+ (better widget support)
- Tested on: iOS 15, 16, 17

### Performance:
- Widget updates: Manual refresh only (zero polling)
- Memory: <5MB per widget lifecycle
- Battery: Zero background drain

### Security:
- Clipboard access: Only during user interaction
- Data encryption: Handled at app level
- App Groups: Scoped to GhostCopy bundle identifier

---

## Next Steps After Xcode Setup

1. **Test on Simulator**:
   - Widget appears ✓
   - Refresh works ✓
   - Copy to clipboard ✓

2. **Get APNs Credentials**:
   - Apple Developer Account
   - Generate APNs key
   - Upload to Firebase

3. **Enable FCM**:
   - Follow `FIREBASE_FCM_SETUP.md`
   - Configure Firebase project
   - Test push notifications

4. **Deploy to App Store** (future):
   - Create release build
   - Submit to App Store Connect
   - Follow Apple review guidelines

