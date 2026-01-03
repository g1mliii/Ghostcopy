# Mobile Push Notifications & Clipboard Sync Implementation Plan

This document outlines the implementation for invisible clipboard sync on mobile devices using Firebase Cloud Messaging (FCM).

## Overview

**Goal**: When desktop copies content, mobile device receives push notification and automatically copies content to clipboard without user interaction.

**User Experience**:
- **iOS**: Notification appears, user can tap to open app OR long-press and select "Copy to Clipboard" action
- **Android**: Notification appears, tap instantly copies content and closes app (transparent activity)
- **Both**: Clipboard content synced invisibly in background

## Architecture

```
Desktop Copy → Supabase Insert → Database Trigger → Edge Function
                                                         ↓
                                      Query clipboard content from DB
                                                         ↓
                              Send FCM with content in data payload (up to 4KB)
                                                         ↓
                          Mobile Receives FCM → Extract from data.clipboard_content
                                                         ↓
                                              Copy to system clipboard
```

## Step 2: iOS Push Notification Setup

### 2.1 Enable Push Capabilities

Edit `ios/Runner.xcodeproj/project.pbxproj` or use Xcode:
1. Open project in Xcode
2. Select Runner target → Signing & Capabilities
3. Click "+ Capability" → Push Notifications
4. Click "+ Capability" → Background Modes
   - Check "Remote notifications"

### 2.2 APNs Authentication Key

1. Go to [Apple Developer Portal](https://developer.apple.com/account/resources/authkeys/list)
2. Create new APNs Authentication Key
3. Download `.p8` file
4. Upload to Firebase Console:
   - Project Settings → Cloud Messaging → iOS app configuration
   - Upload APNs Authentication Key
   - Enter Key ID and Team ID

### 2.3 Actionable Notifications (Long-Press Actions)

Modify `ios/Runner/AppDelegate.swift`:

```swift
import UIKit
import Flutter
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register notification categories with actions
    registerNotificationCategories()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerNotificationCategories() {
    // Define "Copy to Clipboard" action
    let copyAction = UNNotificationAction(
      identifier: "COPY_ACTION",
      title: "Copy to Clipboard",
      options: [.foreground] // Opens app briefly
    )

    // Define category with copy action
    let clipboardCategory = UNNotificationCategory(
      identifier: "CLIPBOARD_SYNC",
      actions: [copyAction],
      intentIdentifiers: [],
      options: []
    )

    // Register category
    UNUserNotificationCenter.current().setNotificationCategories([clipboardCategory])
  }

  // Handle notification action response
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == "COPY_ACTION" {
      // Extract clipboard content from notification
      let clipboardContent = response.notification.request.content.userInfo["clipboard_content"] as? String ?? ""

      // Copy to clipboard
      UIPasteboard.general.string = clipboardContent

      // Optional: Show brief confirmation
      print("Copied to clipboard: \(clipboardContent.prefix(50))...")
    }

    completionHandler()
  }
}
```

## Step 3: Android Push Notification Setup

### 3.1 Transparent Copy Activity

Create `android/app/src/main/kotlin/com/ghostcopy/ghostcopy/CopyActivity.kt`:

```kotlin
package com.ghostcopy.ghostcopy

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * Transparent activity that copies clipboard content and closes immediately.
 * Triggered when user taps push notification.
 */
class CopyActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Extract clipboard content from notification intent
        val clipboardContent = intent.getStringExtra("clipboard_content") ?: ""
        val deviceName = intent.getStringExtra("device_name") ?: "Another device"

        if (clipboardContent.isNotEmpty()) {
            // Copy to system clipboard
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("GhostCopy", clipboardContent)
            clipboard.setPrimaryClip(clip)

            // Optional: Brief toast confirmation (can remove for truly invisible sync)
            Toast.makeText(
                this,
                "Copied from $deviceName",
                Toast.LENGTH_SHORT
            ).show()
        }

        // Close activity immediately
        finish()
    }
}
```

### 3.2 Register Copy Activity

Edit `android/app/src/main/AndroidManifest.xml`:

```xml
<manifest>
    <application>
        <!-- Main activity -->
        <activity
            android:name=".MainActivity"
            android:exported="true"
            <!-- ... existing config ... -->
        </activity>

        <!-- Transparent copy activity for notifications -->
        <activity
            android:name=".CopyActivity"
            android:exported="true"
            android:theme="@android:style/Theme.Translucent.NoTitleBar"
            android:noHistory="true"
            android:excludeFromRecents="true"
            android:launchMode="singleTask" />
    </application>
</manifest>
```

### 3.3 Notification Channel Configuration

Already configured in `lib/main.dart` (lines 170-193), but verify:
- Channel ID: `clipboard_sync`
- Importance: High (for heads-up notifications)
- No sound/vibration for invisible sync (optional - adjust based on UX preference)

## Step 4: Edge Function Update

Modify `supabase/functions/send-clipboard-notification/index.ts` to include clipboard content in FCM payload:

**Current implementation already sends `clipboard_content` in data payload** - verify this is correct:

```typescript
const message = {
  data: {
    clipboard_id: clipboardId.toString(),
    clipboard_content: content,  // ✅ Full clipboard content (up to 4KB)
    device_name: deviceName || 'Unknown Device',
    device_type: deviceType || 'unknown',
  },
  android: {
    priority: 'high',
    notification: {
      title: `Copied from ${deviceName || 'Another device'}`,
      body: content.substring(0, 100) + (content.length > 100 ? '...' : ''),
      clickAction: 'FLUTTER_NOTIFICATION_CLICK',
      channelId: 'clipboard_sync',
    },
    data: {
      // Android notification tap → launches CopyActivity
      click_action: 'COPY_ACTIVITY',
      clipboard_content: content,
    },
  },
  apns: {
    payload: {
      aps: {
        alert: {
          title: `Copied from ${deviceName || 'Another device'}`,
          body: content.substring(0, 100) + (content.length > 100 ? '...' : ''),
        },
        category: 'CLIPBOARD_SYNC', // ✅ Links to iOS notification category
        sound: 'default',
        badge: 1,
      },
      // iOS notification data
      clipboard_content: content,
      device_name: deviceName,
    },
  },
  token: fcmToken,
};
```

**Note**: FCM data payload limit is 4KB. For larger clipboard content, implement fallback to fetch from database.

## Step 5: Flutter Notification Handler

Update `lib/main.dart` notification handlers:

### 5.1 Foreground Notification Handler

Modify `_setupForegroundNotificationHandler()` to auto-copy:

```dart
void _setupForegroundNotificationHandler() {
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    debugPrint('[FCM] Foreground notification received');

    // Extract clipboard content from data payload
    final clipboardContent = message.data['clipboard_content'] as String?;
    final deviceName = message.data['device_name'] as String? ?? 'Another device';

    if (clipboardContent != null && clipboardContent.isNotEmpty) {
      // Auto-copy to clipboard
      final clipboardService = GetIt.instance<IClipboardService>();
      await clipboardService.setText(clipboardContent);

      debugPrint('[FCM] Auto-copied clipboard content from $deviceName');

      // Optional: Show in-app notification (SnackBar/Toast)
      // ... existing notification display logic ...
    }
  });
}
```

### 5.2 Background Notification Handler

Modify `_firebaseMessagingBackgroundHandler()` to auto-copy:

```dart
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('[FCM] Background notification received: ${message.messageId}');

  // Extract clipboard content from data payload
  final clipboardContent = message.data['clipboard_content'] as String?;

  if (clipboardContent != null && clipboardContent.isNotEmpty) {
    try {
      // Initialize services if needed
      if (!GetIt.instance.isRegistered<IClipboardService>()) {
        // Register minimal services for background copy
        // ... service registration ...
      }

      // Auto-copy to clipboard
      final clipboardService = GetIt.instance<IClipboardService>();
      await clipboardService.setText(clipboardContent);

      debugPrint('[FCM] Background auto-copy successful');
    } catch (e) {
      debugPrint('[FCM] Background auto-copy failed: $e');
    }
  }
}
```

### 5.3 Notification Tap Handler (Android)

Modify `_setupNotificationTapHandler()` to launch CopyActivity:

```dart
void _setupNotificationTapHandler() {
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    debugPrint('[FCM] Notification tapped: ${message.messageId}');

    // Android: Intent should have already launched CopyActivity
    // iOS: Auto-copy on tap (alternative to long-press action)
    final clipboardContent = message.data['clipboard_content'] as String?;

    if (clipboardContent != null && clipboardContent.isNotEmpty) {
      final clipboardService = GetIt.instance<IClipboardService>();
      clipboardService.setText(clipboardContent);

      // Close app after brief delay (Android)
      if (Platform.isAndroid) {
        Future.delayed(const Duration(milliseconds: 500), () {
          SystemNavigator.pop(); // Close app
        });
      }
    }
  });
}
```

## Step 6: Android Notification Intent

Update FCM notification configuration to launch CopyActivity on tap.

In `android/app/src/main/kotlin/com/ghostcopy/ghostcopy/MainActivity.kt`, add notification builder:

```kotlin
// This is handled by Firebase messaging plugin + edge function
// Verify edge function sends correct click_action in Android payload
```

**Edge function should already handle this** - verify `clickAction` in Android payload points to CopyActivity.

## Step 7: Testing Checklist

### 7.1 iOS Testing

- [ ] Push notification appears when desktop copies
- [ ] Notification shows correct content preview
- [ ] Long-press notification shows "Copy to Clipboard" action
- [ ] Tapping action copies content and opens app briefly
- [ ] Clipboard content matches source device
- [ ] Background notification delivery works
- [ ] APNs certificate/key valid and uploaded

### 7.2 Android Testing

- [ ] Push notification appears when desktop copies
- [ ] Notification shows correct content preview
- [ ] Tapping notification launches CopyActivity
- [ ] CopyActivity copies content and closes immediately
- [ ] Clipboard content matches source device
- [ ] Background notification delivery works
- [ ] Toast confirmation appears (optional)
- [ ] google-services.json correctly configured

### 7.3 Edge Function Testing

- [ ] FCM tokens stored in Supabase for test devices
- [ ] Edge function triggers on clipboard insert
- [ ] Notification payload includes full clipboard_content
- [ ] Content under 4KB sends successfully
- [ ] Content over 4KB handled gracefully (fallback or truncation)
- [ ] Rate limiting works (60 calls/minute)
- [ ] Firebase Admin SDK authenticated correctly

### 7.4 Cross-Platform Testing

- [ ] Desktop → iOS sync works
- [ ] Desktop → Android sync works
- [ ] iOS → Desktop sync works (existing)
- [ ] Android → Desktop sync works (existing)
- [ ] Multiple devices receive notifications
- [ ] Encrypted content decrypts correctly (if encryption enabled)

## Security Considerations

1. **FCM Token Security**:
   - Tokens stored in Supabase with RLS policies
   - Only user's own tokens accessible
   - Tokens refreshed automatically by Firebase SDK

2. **Clipboard Content in Notifications**:
   - FCM uses TLS encryption in transit
   - Content limited to 4KB (prevents abuse)
   - Sensitive content should use end-to-end encryption (already implemented in EncryptionService)

3. **Notification Permissions**:
   - Request permission on first launch
   - Gracefully handle permission denial
   - Don't break app if notifications disabled

4. **Background Processing**:
   - Android: Respect battery optimization settings
   - iOS: Background notification delivery not guaranteed (use high priority)

## Known Limitations

1. **FCM 4KB Payload Limit**: Large clipboard content (>4KB) may need to be truncated or fetched separately
2. **iOS Background Delivery**: Not guaranteed - use high priority and user may need to open notification
3. **Android Doze Mode**: Notifications may be delayed if device in deep sleep
4. **Notification Permissions**: User must grant permission for push notifications

## Future Enhancements

- [ ] Fallback to database fetch for content >4KB
- [ ] Rich notification content (images, formatted text)
- [ ] Notification grouping for multiple clips
- [ ] Custom notification sounds
- [ ] Notification action history/undo
- [ ] Wi-Fi only sync option to save data
