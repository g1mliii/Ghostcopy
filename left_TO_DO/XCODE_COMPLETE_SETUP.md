# Complete Xcode Setup Guide for GhostCopy iOS


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

---

## Part 9: iOS Share Sheet Extension (Optional - Advanced)

**Status**: Not yet implemented. This is for sharing content FROM other apps TO GhostCopy.

### Why Share Extension is Needed

The current iOS implementation uses URL schemes for sharing, which only supports text:
```swift
// Current: AppDelegate.swift line 104
if url.scheme == "com.ghostcopy.share" {
  if let sharedText = url.host { /* text only */ }
}
```

**URL schemes cannot handle images.** To receive images from Photos, Safari, etc., you need a **Share Extension**.

### Architecture Overview

```
Other App (Photos, Safari)
    ↓ (Share button)
iOS Share Sheet
    ↓ (User selects "GhostCopy")
ShareExtension (separate process)
    ↓ (validates, shows device selector)
Upload to Supabase
    ↓ (shares via App Group)
Main App (gets notified)
```

---

### Step 1: Create Share Extension Target

1. Open `ios/Runner.xcworkspace` in Xcode
2. Select **Runner** project
3. Go to **File** → **New** → **Target**
4. Search for **Share Extension**
5. Click on **Share Extension** template
6. Configure:
   - **Product Name**: `ShareExtension`
   - **Organization**: GhostCopy
   - **Language**: Swift
   - **Interface**: SwiftUI (recommended) or UIKit
7. Click **Finish**

Xcode creates:
```
ios/ShareExtension/
  ShareViewController.swift  (main entry point)
  Info.plist                 (extension configuration)
  ShareExtension.entitlements (capabilities)
```

---

### Step 2: Configure Share Extension Bundle ID

1. Select **ShareExtension** target
2. Go to **General** tab
3. Verify **Bundle Identifier**:
   ```
   com.ghostcopy.ghostcopy.ShareExtension
   ```
   Should automatically be: `$(PRODUCT_BUNDLE_IDENTIFIER).ShareExtension`

---

### Step 3: Enable App Groups for Share Extension

Share Extension runs in a **separate process** from the main app. To share data, use App Groups.

1. Select **ShareExtension** target
2. Go to **Signing & Capabilities** tab
3. Click **+ Capability**
4. Add **App Groups**
5. Select **SAME group** as main app:
   ```
   group.com.ghostcopy.app
   ```

**Critical**: All three targets must use the SAME App Group:
- ✓ Runner: `group.com.ghostcopy.app`
- ✓ ClipboardWidget: `group.com.ghostcopy.app`
- ✓ ShareExtension: `group.com.ghostcopy.app`

---

### Step 4: Configure Info.plist for Activation Rules

The `Info.plist` defines what types of content the extension accepts.

1. Open `ios/ShareExtension/Info.plist`
2. Navigate to: `NSExtension` → `NSExtensionAttributes`
3. Add these activation rules:

```xml
<key>NSExtensionAttributes</key>
<dict>
    <key>NSExtensionActivationRule</key>
    <dict>
        <!-- Accept text -->
        <key>NSExtensionActivationSupportsText</key>
        <true/>

        <!-- Accept up to 1 image -->
        <key>NSExtensionActivationSupportsImageWithMaxCount</key>
        <integer>1</integer>

        <!-- Accept up to 1 file -->
        <key>NSExtensionActivationSupportsFileWithMaxCount</key>
        <integer>1</integer>

        <!-- Accept URLs -->
        <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
        <integer>1</integer>
    </dict>

    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>

    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.share-services</string>
</dict>
```

**What this enables**:
- User shares text → GhostCopy appears in share sheet
- User shares image → GhostCopy appears in share sheet
- User shares file → GhostCopy appears in share sheet
- User shares URL → GhostCopy appears in share sheet

---

### Step 5: Implement ShareViewController.swift

Replace Xcode's template with this implementation:

```swift
import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.ghostcopy.app"
    private let maxImageSizeMB = 10

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProvider = extensionItem.attachments?.first else {
            closeExtension(error: "No content to share")
            return
        }

        // Check content type priority: Image > Text > URL
        if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            handleSharedImage(itemProvider)
        } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            handleSharedText(itemProvider)
        } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            handleSharedURL(itemProvider)
        } else {
            closeExtension(error: "Unsupported content type")
        }
    }

    // MARK: - Image Handling

    private func handleSharedImage(_ itemProvider: NSItemProvider) {
        itemProvider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.closeExtension(error: "Failed to load image: \(error.localizedDescription)")
                return
            }

            // Get image data
            var imageData: Data?
            var mimeType = "image/png"

            if let url = item as? URL {
                // Image provided as file URL
                imageData = try? Data(contentsOf: url)
                mimeType = self.mimeTypeForURL(url)
            } else if let image = item as? UIImage {
                // Image provided as UIImage
                imageData = image.pngData()
            }

            guard let data = imageData else {
                self.closeExtension(error: "Failed to read image data")
                return
            }

            // Validate size (10MB limit)
            let sizeMB = Double(data.count) / (1024 * 1024)
            if sizeMB > Double(self.maxImageSizeMB) {
                self.closeExtension(error: "Image too large (\(String(format: "%.1f", sizeMB))MB). Max 10MB.")
                return
            }

            // Show device selector UI
            DispatchQueue.main.async {
                self.showDeviceSelectorForImage(data, mimeType: mimeType)
            }
        }
    }

    // MARK: - Text Handling

    private func handleSharedText(_ itemProvider: NSItemProvider) {
        itemProvider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.closeExtension(error: "Failed to load text: \(error.localizedDescription)")
                return
            }

            guard let text = item as? String, !text.isEmpty else {
                self.closeExtension(error: "Empty text")
                return
            }

            DispatchQueue.main.async {
                self.showDeviceSelectorForText(text)
            }
        }
    }

    // MARK: - URL Handling

    private func handleSharedURL(_ itemProvider: NSItemProvider) {
        itemProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
            guard let self = self else { return }

            if let error = error {
                self.closeExtension(error: "Failed to load URL: \(error.localizedDescription)")
                return
            }

            guard let url = item as? URL else {
                self.closeExtension(error: "Invalid URL")
                return
            }

            DispatchQueue.main.async {
                self.showDeviceSelectorForText(url.absoluteString)
            }
        }
    }

    // MARK: - Device Selector UI

    private func showDeviceSelectorForImage(_ imageData: Data, mimeType: String) {
        let alert = UIAlertController(
            title: "Share Image",
            message: "Select target devices",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "All Devices", style: .default) { _ in
            self.uploadImage(imageData, mimeType: mimeType, targetDevices: nil)
        })

        alert.addAction(UIAlertAction(title: "Desktop Only", style: .default) { _ in
            self.uploadImage(imageData, mimeType: mimeType, targetDevices: ["windows", "macos"])
        })

        alert.addAction(UIAlertAction(title: "Mobile Only", style: .default) { _ in
            self.uploadImage(imageData, mimeType: mimeType, targetDevices: ["ios", "android"])
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.closeExtension(error: nil)
        })

        present(alert, animated: true)
    }

    private func showDeviceSelectorForText(_ text: String) {
        let alert = UIAlertController(
            title: "Share Text",
            message: "Select target devices",
            preferredStyle: .actionSheet
        )

        alert.addAction(UIAlertAction(title: "All Devices", style: .default) { _ in
            self.saveToAppGroup(text: text, targetDevices: nil)
        })

        alert.addAction(UIAlertAction(title: "Desktop Only", style: .default) { _ in
            self.saveToAppGroup(text: text, targetDevices: ["windows", "macos"])
        })

        alert.addAction(UIAlertAction(title: "Mobile Only", style: .default) { _ in
            self.saveToAppGroup(text: text, targetDevices: ["ios", "android"])
        })

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.closeExtension(error: nil)
        })

        present(alert, animated: true)
    }

    // MARK: - Upload Logic

    private func uploadImage(_ imageData: Data, mimeType: String, targetDevices: [String]?) {
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Uploading...", message: nil, preferredStyle: .alert)
        present(loadingAlert, animated: true)

        // Save to App Group for main app to handle upload
        // (Share Extension cannot import Flutter dependencies)
        let sharedDefaults = UserDefaults(suiteName: appGroupID)

        let shareData: [String: Any] = [
            "type": "image",
            "imageBase64": imageData.base64EncodedString(),
            "mimeType": mimeType,
            "targetDevices": targetDevices ?? [],
            "timestamp": Date().timeIntervalSince1970
        ]

        sharedDefaults?.set(shareData, forKey: "pending_share")
        sharedDefaults?.synchronize()

        // Dismiss and notify main app to process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            loadingAlert.dismiss(animated: false) {
                self.closeExtension(error: nil)

                // Optional: Open main app to process upload
                if let url = URL(string: "ghostcopy://share/process") {
                    self.openURL(url)
                }
            }
        }
    }

    private func saveToAppGroup(text: String, targetDevices: [String]?) {
        let sharedDefaults = UserDefaults(suiteName: appGroupID)

        let shareData: [String: Any] = [
            "type": "text",
            "content": text,
            "targetDevices": targetDevices ?? [],
            "timestamp": Date().timeIntervalSince1970
        ]

        sharedDefaults?.set(shareData, forKey: "pending_share")
        sharedDefaults?.synchronize()

        closeExtension(error: nil)
    }

    // MARK: - Helper Methods

    private func mimeTypeForURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    private func closeExtension(error: String?) {
        if let error = error {
            let alert = UIAlertController(title: "Error", message: error, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            })
            present(alert, animated: true)
        } else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    @objc private func openURL(_ url: URL) {
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.perform(#selector(openURL(_:)), with: url)
                return
            }
            responder = responder?.next
        }
    }
}
```

---

### Step 6: Handle Shared Content in Main App

Update `AppDelegate.swift` to process shared content from the extension:

```swift
// Add to AppDelegate.swift

override func application(
  _ application: UIApplication,
  open url: URL,
  options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
  // ... existing code ...

  // Handle share extension callback
  if url.scheme == "ghostcopy" && url.host == "share" && url.lastPathComponent == "process" {
    processSharedContent()
  }

  return super.application(application, open: url, options: options)
}

private func processSharedContent() {
  guard let sharedDefaults = UserDefaults(suiteName: "group.com.ghostcopy.app"),
        let shareData = sharedDefaults.dictionary(forKey: "pending_share") else {
    return
  }

  // Clear pending share
  sharedDefaults.removeObject(forKey: "pending_share")
  sharedDefaults.synchronize()

  // Forward to Flutter via method channel
  guard let controller = window?.rootViewController as? FlutterViewController else { return }

  let shareChannel = FlutterMethodChannel(
    name: "com.ghostcopy.ghostcopy/share",
    binaryMessenger: controller.binaryMessenger
  )

  if let type = shareData["type"] as? String, type == "image" {
    shareChannel.invokeMethod("handleShareImage", arguments: shareData)
  } else {
    shareChannel.invokeMethod("handleShareIntent", arguments: shareData)
  }
}
```

---

### Step 7: Build & Test

1. Select **ShareExtension** scheme from top dropdown
2. Build: **Cmd+B**
3. Run on **physical device** (Share Extensions don't work reliably on simulator)
4. Open Photos app
5. Select an image
6. Tap Share button
7. Look for **"GhostCopy"** in the share sheet
8. Tap it → device selector appears
9. Select target devices
10. Verify main app receives and uploads

---

### Troubleshooting Share Extension

**"GhostCopy doesn't appear in share sheet"**:
- Check Info.plist activation rules are correct
- Verify bundle ID is `com.ghostcopy.ghostcopy.ShareExtension`
- Rebuild main app AND share extension
- Delete app from device and reinstall

**"Share extension crashes immediately"**:
- Check Console.app for crash logs
- Verify ShareViewController.swift compiles
- Check that AppGroups are configured identically across all 3 targets

**"Can't share images, only text"**:
- Verify NSExtensionActivationSupportsImageWithMaxCount is set
- Check itemProvider.hasItemConformingToTypeIdentifier uses UTType.image

**"Main app doesn't receive shared content"**:
- Verify App Group identifier matches exactly
- Check that UserDefaults(suiteName:) uses correct group
- Add debug logging to processSharedContent()

---

## Summary: Three Extensions for GhostCopy iOS

| Extension | Purpose | Status |
|-----------|---------|--------|
| **ClipboardWidget** | Home screen widget showing recent clips | ✅ Implemented |
| **ShareExtension** | Receive shares from other apps | 📝 Documented (not yet implemented) |
| **NotificationServiceExtension** | (Future) Modify FCM notifications before display | ❌ Not planned |

**Recommendation**: Implement ShareExtension after basic iOS features are stable and tested.

