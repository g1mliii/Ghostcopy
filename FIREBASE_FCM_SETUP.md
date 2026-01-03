# Firebase Cloud Messaging (FCM) Setup Guide

This guide explains how to complete Firebase FCM setup for GhostCopy once you receive APNs credentials from Apple.

## Current Status

✅ **Code Infrastructure**: Complete
- Dart/Flutter FCM handling ready
- Android FCM service implemented
- iOS notification handlers ready
- Widget integration ready
- Actionable notifications configured

⏳ **Credentials Needed**:
- [ ] Apple APNs certificate (.p8 or .cer)
- [ ] Firebase project with iOS app configured
- [ ] GoogleService-Info.plist file

---

## Prerequisites

Before you begin, ensure you have:
1. **Apple Developer Account** (paid membership required)
2. **Firebase Project** (create at console.firebase.google.com)
3. **GhostCopy iOS & Android apps** registered in Firebase
4. **APNs certificates** from Apple Developer Portal

---

## Step 1: Set Up Firebase Project

### 1.1 Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click "Create a project"
3. Enter project name: `GhostCopy`
4. Click "Create project"
5. Wait for project creation to complete

### 1.2 Add iOS App to Firebase

1. In Firebase console, click **Settings** (gear icon) → **Project settings**
2. Go to **Integrations** tab
3. Find **iOS** and click **Add app**
4. Fill in:
   - **iOS Bundle ID**: `com.ghostcopy.ghostcopy`
   - **App nickname**: (optional)
5. Click **Register app**
6. Download **GoogleService-Info.plist**
7. Copy it to: `ios/Runner/GoogleService-Info.plist`

### 1.3 Add Android App to Firebase

1. In Firebase console, click **Add app** → **Android**
2. Fill in:
   - **Android Package Name**: `com.ghostcopy.ghostcopy`
   - **App nickname**: (optional)
   - **SHA-1 Fingerprint**: Get from running `flutter pub run flutter_config:config` (optional for now)
3. Click **Register app**
4. Download **google-services.json**
5. Copy it to: `android/app/google-services.json`

---

## Step 2: Set Up APNs Certificate

This is the critical step. You need an APNs certificate to send notifications to iOS.

### 2.1 Generate APNs Key in Apple Developer

1. Go to [Apple Developer Portal](https://developer.apple.com)
2. Login with Apple ID
3. Go to **Certificates, Identifiers & Profiles**
4. Select **Keys** in the sidebar
5. Click **Create a new key** (blue "+" button)
6. Name: `GhostCopy FCM Key`
7. Check **Apple Push Notifications service (APNs)**
8. Click **Continue**
9. Click **Register**
10. **IMPORTANT**: Download the `.p8` file and save it securely
    - You can only download once - keep it safe!
    - This is your **Key ID** (e.g., `ABC123DEFG`)

### 2.2 Get Your Team ID

1. In Apple Developer, go to **Membership**
2. Note your **Team ID** (e.g., `ABCD123456`)
3. You'll need this later

### 2.3 Get Your Bundle ID

1. In Apple Developer, go to **Identifiers**
2. Select your app identifier (should be `com.ghostcopy.ghostcopy`)
3. Note the full Bundle ID

---

## Step 3: Upload APNs to Firebase

### 3.1 Add APNs Certificate to Firebase

1. In Firebase console, go to **Settings** → **Cloud Messaging**
2. Scroll to **Apple app configuration**
3. Upload your APNs key:
   - Click **Upload** button
   - Select your `.p8` file
   - Enter **Key ID** (from Apple Developer)
   - Enter **Team ID** (from Apple Developer)
4. Click **Upload**

Firebase will verify the certificate and save it.

---

## Step 4: Configure Payload Format

Your FCM notification payload should have this format for iOS:

```json
{
  "notification": {
    "title": "New Clipboard Item",
    "body": "From iPhone: Hello World",
    "badge": "1",
    "sound": "default"
  },
  "data": {
    "clipboard_id": "12345",
    "clipboard_content": "Hello World",
    "content_type": "text",
    "content_preview": "Hello World",
    "device_type": "iPhone",
    "device_name": "John's iPhone",
    "is_encrypted": false
  },
  "apns": {
    "payload": {
      "aps": {
        "category": "CLIPBOARD_SYNC",
        "mutable-content": 1,
        "sound": "default",
        "badge": 1
      }
    }
  }
}
```

### Key Fields Explained:

**notification** (optional display):
- `title`: Notification title
- `body`: Notification body
- `badge`: Red badge on app icon
- `sound`: Notification sound (default or custom)

**data** (app-specific):
- `clipboard_id`: Database ID for clipboard item
- `clipboard_content`: Full content (for items < 4KB)
- `content_type`: "text", "image", "json", "html", etc.
- `content_preview`: Truncated preview (< 100 chars)
- `device_type`: Source device (iPhone, Mac, Android, etc.)
- `is_encrypted`: Whether content is encrypted

**apns** (iOS-specific):
- `category`: Must be `CLIPBOARD_SYNC` (matches our registered category)
- `mutable-content`: Allows notification customization (value: 1)
- `sound`: Notification sound
- `badge`: Badge number

---

## Step 5: Test FCM on Device

### 5.1 Get FCM Token

1. Build and run the app:
   ```bash
   flutter run -d ios
   ```

2. Check console output for:
   ```
   [App] Got FCM token: <token_here>
   ```

3. Copy this token (save for testing)

### 5.2 Send Test Notification

**Using Firebase Console:**

1. Firebase Console → **Messaging**
2. Click **Create your first campaign**
3. Select **Firebase Cloud Messaging**
4. Compose notification:
   - **Title**: "Test Notification"
   - **Body**: "Testing GhostCopy FCM"
5. Click **Send test message**
6. Select **Add an FCM registration token**
7. Paste your FCM token
8. Click **Test**

**Using cURL (for backend):**

```bash
curl -X POST https://fcm.googleapis.com/v1/projects/<project-id>/messages:send \
  -H "Authorization: Bearer <access-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "message": {
      "token": "<fcm-token>",
      "notification": {
        "title": "Test Notification",
        "body": "Testing GhostCopy FCM"
      },
      "data": {
        "clipboard_id": "test123",
        "clipboard_content": "Hello from FCM!",
        "content_type": "text",
        "content_preview": "Hello from FCM!",
        "device_type": "Test Device",
        "is_encrypted": "false"
      },
      "apns": {
        "payload": {
          "aps": {
            "category": "CLIPBOARD_SYNC",
            "mutable-content": 1,
            "sound": "default",
            "badge": 1
          }
        }
      }
    }
  }'
```

**Expected Results:**

- ✅ Notification appears on home screen
- ✅ Notification has "Copy", "Dismiss", "Details" action buttons
- ✅ Tapping "Copy" adds content to clipboard
- ✅ Tapping notification opens app
- ✅ Widget updates with new item

### 5.3 Check Console Logs

In Xcode Console, look for:
```
[FCM] Received message: <message-id>
[Notification] 📬 Action: Copy to Clipboard
✅ Copied to clipboard from Test Device
[WidgetDataManager] ✅ Saved 1 items to shared storage
[AppDelegate] ✅ Widget updated with FCM notification
```

---

## Step 6: Set Up Backend Integration

Once FCM is working, update your backend (Supabase Edge Function) to send notifications:

### 6.1 Firebase Admin SDK Setup

Use Firebase Admin SDK in your backend to send notifications:

**Python Example:**

```python
import firebase_admin
from firebase_admin import credentials, messaging

# Initialize Firebase (use service account key)
cred = credentials.Certificate('path/to/serviceAccountKey.json')
firebase_admin.initialize_app(cred)

# Send notification
message = messaging.MulticastMessage(
    data={
        'clipboard_id': str(item_id),
        'clipboard_content': content,
        'content_type': content_type,
        'content_preview': preview,
        'device_type': 'Desktop',
        'is_encrypted': 'false',
    },
    tokens=fcm_tokens,  # List of user's device FCM tokens
    notification=messaging.Notification(
        title='New Clipboard Item',
        body=f'From {device_name}: {preview}',
    ),
    apns=messaging.APNSConfig(
        payload=messaging.APNSPayload(
            aps=messaging.APNSMessage(
                alert=messaging.APS_ALERT_UNKNOWN,
                category='CLIPBOARD_SYNC',
                mutable_content=True,
                sound='default',
            ),
        ),
    ),
    android=messaging.AndroidConfig(
        priority='high',
        notification=messaging.AndroidNotification(
            title='New Clipboard Item',
            body=f'From {device_name}: {preview}',
            channel_id='clipboard_sync',
        ),
    ),
)

response = messaging.send_multicast(message)
print(f'Successfully sent {response.success_count} notifications')
```

**Node.js Example:**

```javascript
const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const message = {
  data: {
    clipboard_id: itemId.toString(),
    clipboard_content: content,
    content_type: contentType,
    content_preview: preview,
    device_type: 'Desktop',
    is_encrypted: 'false',
  },
  notification: {
    title: 'New Clipboard Item',
    body: `From ${deviceName}: ${preview}`,
  },
  apns: {
    payload: {
      aps: {
        category: 'CLIPBOARD_SYNC',
        'mutable-content': 1,
        sound: 'default',
      },
    },
  },
  android: {
    priority: 'high',
    notification: {
      title: 'New Clipboard Item',
      body: `From ${deviceName}: ${preview}`,
      channelId: 'clipboard_sync',
    },
  },
};

admin.messaging().sendMulticast({
  tokens: fcmTokens, // Array of device FCM tokens
  ...message,
});
```

### 6.2 Store FCM Tokens in Database

Make sure your app stores FCM tokens:

In Supabase, add to `auth.users` metadata or create a `devices` table:

```sql
-- Option 1: Store in user metadata (simple)
UPDATE auth.users
SET raw_user_meta_data = jsonb_set(
  raw_user_meta_data,
  '{fcm_token}',
  to_jsonb($1)
)
WHERE id = $2;

-- Option 2: Create devices table
CREATE TABLE devices (
  id BIGINT PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
  user_id UUID REFERENCES auth.users NOT NULL,
  fcm_token TEXT NOT NULL,
  device_type TEXT, -- 'ios', 'android', 'windows', 'macos'
  device_name TEXT,
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, device_type)
);
```

---

## Troubleshooting

### Issue: "Certificate is invalid"
- **Solution**: Verify you uploaded the correct `.p8` file from Apple
- Make sure Key ID and Team ID match Apple Developer Portal
- Re-download the key if unsure

### Issue: "Notification not arriving on iOS"
- **Check 1**: Verify `category` in `apns` payload is exactly `CLIPBOARD_SYNC`
- **Check 2**: Ensure `mutable-content: 1` is set in `aps`
- **Check 3**: Confirm FCM token is current (tokens can expire)
- **Check 4**: Check Firebase Console → Messaging → Logs for delivery status

### Issue: "Clipboard content not copying"
- **Check 1**: Verify `clipboard_content` is in `data` payload (not `notification`)
- **Check 2**: Ensure user tapped action button (not just notification)
- **Check 3**: Check console for: `✅ Copied to clipboard from...`

### Issue: "Action buttons not showing"
- **Check 1**: iOS 10+? Action buttons require iOS 10+
- **Check 2**: Verify `category: CLIPBOARD_SYNC` in payload
- **Check 3**: Check that `registerNotificationCategories()` was called in AppDelegate
- **Check 4**: Rebuild app - notification categories cached at startup

### Issue: "Widget not updating"
- **Check 1**: Verify `WidgetCenter.reloadAllTimelines()` is called
- **Check 2**: Check App Group identifier: `group.com.ghostcopy.app`
- **Check 3**: Verify entitlements files have correct App Group
- **Check 4**: Check console for: `[WidgetDataManager] ✅ Saved...`

---

## Memory Leak Prevention Checklist

✅ **AppDelegate**
- Uses `[weak self]` in method channel closures
- Proper `completionHandler` calls in notification handlers
- No retained notification center observers

✅ **ActionableNotificationManager**
- Singleton with safe initialization
- No retained notification objects
- Proper cleanup on notification category update

✅ **RefreshWidgetIntent**
- URLSession created with proper timeouts
- Task completion handlers properly called
- No retained session objects

✅ **WidgetDataManager**
- Weak delegate references
- Proper UserDefaults cleanup
- No circular references

---

## Monitoring & Debugging

### Enable Firebase Debug Logging

**iOS:**
```swift
// In main() or AppDelegate.didFinishLaunching
FirebaseApp.configure()
FirebaseConfiguration.shared.setLoggerLevel(.debug)
```

**Android:**
```kotlin
// In FirebaseMessagingService
Log.d("FCM", "Received message: ${remoteMessage.data}")
```

### Check FCM Delivery Status

1. Firebase Console → **Messaging**
2. Select a message
3. View **Delivery status** and **Errors**
4. Click on failed devices to see error details

### Check Device FCM Token

The app logs FCM token on startup:
```
[App] Got FCM token: <token_here>
```

Ensure token is valid:
1. It should be 152+ characters
2. It should not contain spaces
3. Copy entire token (some tools truncate)

---

## Security Considerations

### 1. Sensitive Data in FCM

⚠️ **Don't send sensitive data**:
- Passwords
- Encryption keys
- Personal financial data
- Health information

✅ **Safe to send**:
- Clipboard previews (truncated)
- Device names
- Clipboard item IDs
- Content type indicators

### 2. Firebase Security Rules

Add rules to restrict token access:

```javascript
// In Firebase Console → Database Rules
match /devices/{document=**} {
  allow read, write: if request.auth.uid == resource.data.user_id;
  allow create: if request.auth.uid != null;
}
```

### 3. Encryption for Large Content

For content > 4KB:
1. Send only `clipboard_id` in notification
2. App fetches full content from Supabase on notification tap
3. Use Row-Level Security to ensure user can only see their clipboard items

---

## Testing Checklist

- [ ] Firebase project created
- [ ] iOS app registered in Firebase
- [ ] Android app registered in Firebase
- [ ] APNs key generated in Apple Developer
- [ ] APNs key uploaded to Firebase with Key ID and Team ID
- [ ] GoogleService-Info.plist downloaded and placed in `ios/Runner/`
- [ ] google-services.json downloaded and placed in `android/app/`
- [ ] App builds without errors
- [ ] FCM token logged on startup
- [ ] Test notification received on device
- [ ] Notification action buttons appear (long-press on iOS)
- [ ] Copy action works
- [ ] Clipboard content updated
- [ ] Widget updated
- [ ] No memory leaks (check Xcode Profiler)

---

## Additional Resources

- [Firebase Cloud Messaging Documentation](https://firebase.google.com/docs/cloud-messaging)
- [Apple Push Notification Service (APNs)](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server)
- [Flutter Firebase Plugin](https://pub.dev/packages/firebase_messaging)
- [iOS Notification Best Practices](https://developer.apple.com/design/human-interface-guidelines/notifications)

---

## Summary

Once you have:
1. ✅ APNs certificate from Apple
2. ✅ Firebase project configured
3. ✅ GoogleService-Info.plist and google-services.json

**No code changes needed!** The infrastructure is complete:
- iOS notification handlers are ready
- Widget integration is ready
- Actionable notifications configured
- Memory leak protection in place

Just configure Firebase and test with the payload format provided above.

