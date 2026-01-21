# Final Remaining Steps to Complete GhostCopy iOS/macOS

## 🎯 Remaining Work (In Order)

---

## Phase 1: Test macOS Features (On macOS)

**Where**: Your Mac computer
**Time**: ~30 minutes
**Command**:
```bash
flutter run -d macos
```

### What to Test:
- ✅ App launches and window is hidden
- ✅ System tray icon appears
- ✅ Press **Ctrl+Shift+S** → Spotlight window shows
- ✅ Right-click tray icon → menu appears
- ✅ Settings, Game Mode, Quit options work
- ✅ Put Mac to sleep → check console for power events
- ✅ Wake Mac → app still responds to hotkey

### Document to Reference:
→ `MACOS_SETUP_VERIFICATION.md` (Testing section)

### If Issues:
Check troubleshooting in `MACOS_SETUP_VERIFICATION.md`

---

## Phase 2: Set Up Apple Developer Account (iOS Dev Credentials)

**Time**: ~1 hour
**Requirements**: Apple ID + $99/year developer membership

### 2.1 Enroll in Apple Developer Program
1. Go to [developer.apple.com](https://developer.apple.com)
2. Sign in with Apple ID (create if needed)
3. Enroll in Apple Developer Program ($99/year)
4. Complete enrollment process

### 2.2 Get Your Team ID
1. In Apple Developer Portal → **Membership** tab
2. Note your **Team ID** (e.g., `ABCD123456`)
3. Save this - you'll need it for Firebase

### 2.3 Create App Identifier
1. Apple Developer → **Identifiers**
2. Click **+** to create new identifier
3. Select **App IDs**
4. Fill in:
   - **Description**: GhostCopy iOS App
   - **Bundle ID**: `com.ghostcopy.ghostcopy`
5. Click **Continue** → **Register**

### 2.4 Create Provisioning Profile (Optional for Testing)
1. Apple Developer → **Provisioning Profiles**
2. Click **+** to create new
3. Select **iOS App Development**
4. Select the App ID you just created
5. Select your dev certificate and device
6. Download and install in Xcode

### 2.5 Generate APNs Key (For FCM)
**THIS IS CRITICAL FOR FCM**

1. Apple Developer → **Keys**
2. Click **+** to create new key
3. Check **Apple Push Notifications service (APNs)**
4. Name it: `GhostCopy FCM Key`
5. Click **Continue** → **Register**
6. **⚠️ IMPORTANT**: Download the `.p8` file
   - You can only download ONCE
   - Keep it safe - can't re-download!
   - Save with name: `ghostcopy_apns_key.p8`
7. Note your **Key ID** (e.g., `ABC123DEFG`)
8. Save both the Key ID and Team ID - needed for Firebase

---

## Phase 3: Set Up Xcode Project (Bundle IDs, Code Signing, Entitlements)

**Where**: On your Mac in Xcode
**Time**: ~45 minutes
**Document**: `XCODE_COMPLETE_SETUP.md` (follow step-by-step)

### Quick Checklist:
- [ ] Open `ios/Runner.xcworkspace` in Xcode
- [ ] Set signing team for **Runner** target
- [ ] Set signing team for **ClipboardWidget** target
- [ ] Add **App Groups** capability to both targets: `group.com.ghostcopy.app`
- [ ] Add **Push Notifications** capability to **Runner** target
- [ ] Verify bundle IDs:
  - Runner: `com.ghostcopy.ghostcopy`
  - Widget: `com.ghostcopy.ghostcopy.ClipboardWidget`
- [ ] Create **Widget Extension** target:
  - File → New → Target → Widget Extension
  - Product Name: `ClipboardWidget`
- [ ] Copy 4 Swift files to widget target
- [ ] Add **GoogleService-Info.plist** to Runner target
- [ ] Clean build: **Cmd+Shift+K** then **Cmd+B**
- [ ] Test on simulator: **Cmd+R**


## Phase 4: Set Up Firebase Project & FCM

**Where**: Firebase Console + Google Cloud Console
**Time**: ~1 hour
**Documents**: `FIREBASE_FCM_SETUP.md` + `XCODE_COMPLETE_SETUP.md`

### 4.1 Create Firebase Project
1. Go to [Firebase Console](https://console.firebase.google.com)
2. Click **Create a project**
3. Name: `GhostCopy`
4. Wait for project creation

### 4.2 Register iOS App in Firebase
1. Firebase Console → Select **GhostCopy** project
2. Click **+ Add app** → **iOS**
3. Fill in:
   - **iOS Bundle ID**: `com.ghostcopy.ghostcopy`
   - **App nickname**: GhostCopy iOS
   - **App Store ID**: (leave empty for now)
4. Click **Register app**
5. **Download GoogleService-Info.plist**
6. Add to Xcode:
   - Right-click **Runner** folder in Xcode
   - Select **Add Files to Runner**
   - Select downloaded plist
   - ☑️ Copy items if needed
   - ☑️ Runner target only
   - Click **Add**

### 4.3 Register Android App in Firebase (Optional but Recommended)
1. Firebase Console → **Add app** → **Android**
2. Fill in:
   - **Android Package Name**: `com.ghostcopy.ghostcopy`
   - **App nickname**: GhostCopy Android
3. Download `google-services.json`
4. Add to: `android/app/google-services.json`

### 4.4 Upload APNs Key to Firebase
**THIS ENABLES FCM FOR iOS**

1. Firebase Console → **Settings** (gear icon) → **Cloud Messaging** tab
2. Scroll to **Apple app configuration**
3. Click **Upload**
4. Select your `.p8` file (from Apple Developer)
5. Enter **Key ID** (from Apple Developer)
6. Enter **Team ID** (from Apple Developer)
7. Click **Upload**

### 4.5 Test FCM
1. Build and run app on device (simulator doesn't support FCM):
   ```bash
   flutter build ios
   # Then run on device in Xcode
   ```
2. Get FCM token from console output:
   ```
   [App] Got FCM token: <token_here>
   ```
3. Firebase Console → **Messaging** tab
4. Click **Create your first campaign**
5. Select **Firebase Cloud Messaging**
6. Compose test notification:
   - Title: "Test"
   - Body: "Testing GhostCopy FCM"
7. Click **Send test message**
8. Add FCM token
9. Click **Test**


## Phase 5: Configure Backend (Supabase Edge Function)

**Where**: Supabase Edge Functions
**Time**: ~30 minutes
**Document**: `FIREBASE_FCM_SETUP.md` (Step 6 - Backend Integration)

### What to Do:
Update `supabase/functions/send-clipboard-notification/index.ts` to:

1. Get list of user's FCM tokens from database
2. Send FCM message with proper payload format:
   ```json
   {
     "data": {
       "clipboard_id": "...",
       "clipboard_content": "...",
       "content_type": "...",
       "content_preview": "...",
       "device_type": "...",
       "is_encrypted": "false"
     },
     "apns": {
       "payload": {
         "aps": {
           "category": "CLIPBOARD_SYNC",
           "mutable-content": 1,
           "sound": "default"
         }
       }
     }
   }
   ```

3. Store FCM tokens in Supabase database (in user's device list)

### Reference Code:
See `FIREBASE_FCM_SETUP.md` - Section "Step 6: Backend Integration"
- Python example
- Node.js example


#### Testing Phase:
- [ ] **macOS Test** (30 min)
  - Run `flutter run -d macos`
  - Test hotkey, tray menu, sleep/wake events

#### Apple Developer Setup (1-2 hours):
- [ ] Create Apple Developer account ($99/year)
- [ ] Get Team ID
- [ ] Create App Identifier (`com.ghostcopy.ghostcopy`)
- [ ] Generate APNs key (`.p8` file) ← **Save safely!**
- [ ] Note Key ID and Team ID

#### Xcode Setup (45 min):
- [ ] Open `ios/Runner.xcworkspace`
- [ ] Set signing teams
- [ ] Add App Groups capability (both targets)
- [ ] Add Push Notifications capability
- [ ] Create Widget Extension target
- [ ] Add GoogleService-Info.plist
- [ ] Build and test on simulator

#### Firebase Setup (1 hour):
- [ ] Create Firebase project
- [ ] Register iOS app
- [ ] Register Android app (optional)
- [ ] Download GoogleService-Info.plist
- [ ] Download google-services.json
- [ ] **Upload APNs key to Firebase** ← **Critical!**
- [ ] Test FCM on physical device

#### Backend Integration (30 min):
- [ ] Update Supabase Edge Function
- [ ] Send FCM messages with correct payload
- [ ] Store FCM tokens in database

---

## Estimated Total Time

| Phase | Time |
|-------|------|
| macOS testing | 30 min |
| Apple Developer setup | 1-2 hours |
| Xcode project setup | 45 min |
| Firebase setup | 1 hour |
| Backend integration | 30 min |
| **Total** | **4-5 hours** |

---

## Documents to Reference

1. **XCODE_COMPLETE_SETUP.md** - Complete Xcode guide (Parts 1-7)
2. **FIREBASE_FCM_SETUP.md** - Firebase setup (Steps 1-6)
3. **MACOS_SETUP_VERIFICATION.md** - macOS testing checklist
4. **REMAINING_SETUP_STEPS.md** - This document

---

## Critical Files/Credentials to Save

⚠️ **Keep these safe**:
- `.p8` APNs key file (can't re-download!)
- Team ID (from Apple Developer)
- Key ID (from Apple Developer)
- GoogleService-Info.plist
- google-services.json

---

## Order of Execution

```
1. Test macOS features ← Easy test first
     ↓
2. Set up Apple Developer account ← Prerequisites
     ↓
3. Set up Xcode project ← Can't skip, required for iOS
     ↓
4. Set up Firebase & upload APNs ← Enables FCM
     ↓
5. Update backend (Edge Function) ← Makes FCM actually send
```

---

## Success Criteria

When complete, you should be able to:
- ✅ Run desktop app on Mac with hotkey/tray
- ✅ Run iOS app in Xcode simulator
- ✅ Add widget to home screen
- ✅ Tap widget item to copy clipboard
- ✅ Send test FCM notification
- ✅ Receive notification with action buttons
- ✅ Tap "Copy" action to write to clipboard
- ✅ Widget updates automatically
- ✅ No memory leaks or crashes

---

## Questions?

If stuck on any step:
1. Check relevant document (XCODE_COMPLETE_SETUP.md or FIREBASE_FCM_SETUP.md)
2. Check troubleshooting sections
3. Search for error message in docs
4. All setup is standard iOS/Firebase - solutions available online

