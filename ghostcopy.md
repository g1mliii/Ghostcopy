ClpBrd
perf optimizations
"Ensure the Flutter Windows build is optimized for performance. Use const widgets everywhere to reduce memory, and implement a TickerProvider that pauses completely when the window is hidden."

**The "Zero-CPU" Sleep Trick**

When your window is hidden (99% of the time), you don't want the app "thinking" or trying to render 60 frames per second of invisible emptiness.

**Add this logic to your window_manager listener:**

Dart

pseudocode logic for your main.dart

void onWindowBlur() {

  // 1. App is hidden/minimized

  // STOP all animations

  // PAUSE any heavy listeners

  setState(() { isSleeping = true; });

}

void onWindowFocus() {

  // 2. You hit Ctrl+Shift+S

  // WAKE UP the UI

  setState(() { isSleeping = false; });

}





cool extra features
The "Dev-Tools" Transformer (Easy Win)**

Since you are a coder, you likely copy messy JSON or JWT tokens constantly.

- **The Feature:** When you press Ctrl+Shift+S, your app detects the _format_ of the text.
- **If it sees JSON:** It offers a "Prettify" button (formats it instantly before you paste).
- **If it sees a JWT:** It decodes the payload (shows you the exp date and user_id inside the token).
- **If it sees a Hex Code (#FF0000):** It shows a small color square next to the text.
- **Why it’s cool:** It turns your clipboard into a mini-IDE.
- **Flutter Package:** dart_jsonwebtoken and convert.

**2. "Magic Link" Previews (Visual Polish)**

Instead of your history looking like a wall of blue URLs, make it look like iMessage or Discord.

- **The Feature:** When you copy a URL, your app silently fetches the "Open Graph" metadata (Title, Image, Description).
- **The UI:** Your history list shows a rich card with the website's thumbnail instead of just https://....
- **Flutter Package:** any_link_preview or metadata_fetch.

# Product Specification: Universal Clipboard 

## Vision
A seamless, real-time cross-platform clipboard synchronization tool. It allows a user to copy text on one device (Windows Desktop) and immediately have it available on another (iOS/Android/macOS), and vice versa.

The experience should be "invisible" (no friction) and "intelligent" (handling specific data types smartly).

## Core User Flows

### 1. The "Ghost" Send (Desktop - Windows/macOS)
- **Trigger:** User highlights text in ANY app and presses the Global Hotkey (`Ctrl+Shift+S`).
- **Action:** A hidden, borderless window appears instantly in the center of the screen, pre-filled with the copied text.
- **Outcome:** User hits ENTER -> Text is sent to Supabase -> Window vanishes.

### 2. The "Blink" Receive (Mobile)
- **Trigger:** Mobile device receives a Push Notification: "New Clipboard Item".
- **Action:** User taps notification -> App opens -> Auto-copies text to local clipboard -> Shows "Copied!" toast -> App minimizes/closes.
- **Widget Flow:** User can also tap a "Get Latest" button on their Home Screen Widget to fetch the last clip without opening the full app navigation.

### 3. The "Stash" (History)
- **UI:** Users can open the main app to see a scrollable history of the last 50 copied items.
- **Sorting:** Items are sorted by date (newest first).

### 4. Game Mode Protection (Desktop)
- **Trigger:** App detects a full-screen application is active (or user toggles "Game Mode" in tray).
- **Behavior:**
    - *Sending:* Hotkeys still work.
    - *Receiving:* Incoming clips are silently queued in the background. NO visual toasts or windows appear until the user alt-tabs or exits the game.

### 5. Smart Transformers (Power User Features)
- **JSON Detection:** If text is JSON, show a "Prettify" button.
- **JWT Detection:** If text is a token, decode and show the payload.
- **Hex Colors:** Show a color preview square next to the hex code.

## Design Philosophy
- **Invisible:** The app should feel like part of the OS, not a separate program.
- **Fast:** Max interaction time should be < 2 seconds.
- **Privacy:** By default, data is private to the user's `user_id`.
## Design Philosophy

- **Invisible:** The app should feel like part of the OS, not a separate program.

- **Fast:** Max interaction time should be < 2 seconds.

- **Privacy:** By default, data is private to the user's `device_id` group.

---
# Technical Stack & Dependencies

## Core Framework
- **Frontend:** Flutter (Stable Channel)
- **Backend:** Supabase (PostgreSQL + Realtime)
- **Language:** Dart 3.x

## Target Platforms
1. **Windows 11** (Primary Dev Environment)
2. **macOS** (Secondary Desktop)
3. **Android/iOS** (Mobile Receivers)
*(Linux support postponed to Phase 3)*

## Critical Flutter Packages

| Package | Purpose | Notes |
| :--- | :--- | :--- |
| `supabase_flutter` | Auth & Database | Must enable Realtime in dashboard. |
| `window_manager` | Custom Window Frame | Set `TitleBarStyle.hidden` for "Spotlight" look. |
| `hotkey_manager` | Global Shortcuts | Listens for `Ctrl+Shift+S` in background. |
| `tray_manager` | System Tray Icon | For "Quit" menu since window has no buttons. |
| `flutter_local_notifications` | Mobile Alerts | Handle "Tap to Copy" logic. |
| `home_widget` | Mobile Widgets | Bridges Flutter data to iOS Today View / Android Widgets. |
| `launch_at_startup` | OS Integration | Essential for background utility. |
| `dart_jsonwebtoken` | Smart Feature | For decoding tokens locally. |

## Performance Optimization (The "Zero-CPU" Rule)
To ensure zero impact on gaming performance:
- Implement a `AppLifecycleListener`.
- When `window_manager` is hidden: Call `setState(() { isSleeping = true; })`.
- This must pause all TickerProviders (animations) and stop non-essential streams.

## Database Schema (Supabase) not final can be adjusted

```sql
TABLE clipboard (
  id bigint PRIMARY KEY generated by default as identity,
  user_id uuid REFERENCES auth.users NOT NULL,
  content text NOT NULL,
  device_name text,                -- e.g. "My Gaming PC"
  device_type text,                -- e.g. "windows", "macos", "mobile"
  is_public boolean DEFAULT false, -- For future sharing features
  created_at timestamp WITH time zone DEFAULT timezone('utc'::text, now())
);

-- Enable Row Level Security (RLS)
ALTER TABLE clipboard ENABLE ROW LEVEL SECURITY;
-- Note: Enable Realtime for INSERT on this table in Supabase Dashboard.

---

# Implementation Plan

## Phase 1: The "Invisible" Desktop Base (Windows)
- [ ] Initialize Flutter project with Windows, macOS, Android, iOS support.
- [ ] Install `window_manager` and configure `TitleBarStyle.hidden`.
- [ ] Implement `hotkey_manager` to toggle window visibility on `Ctrl+Shift+S`.
- [ ] Implement the "Zero-CPU" sleep logic (pause animations when hidden).
- [ ] Create the "Spotlight" UI (TextField + Send Button).

## Phase 2: The Backend Link
- [ ] Connect `supabase_flutter`.
- [ ] Execute SQL Schema setup in Supabase Dashboard.
- [ ] Implement `sendToCloud(String text)` function.
- [ ] Verify data appears in Supabase Dashboard.

## Phase 3: The macOS Port
- [ ] Configure macOS App Sandbox entitlements (Network Client).
- [ ] Add logic to request "Accessibility Permissions" on startup (required for Hotkeys).
- [ ] Verify `tray_manager` icon appears in the top Menu Bar.

## Phase 4: Mobile Receiver & Widgets
- [ ] Build basic List View of history.
- [ ] Implement Push Notification trigger (Tap -> Copy).
- [ ] **Widget:** Set up `home_widget` to display the last 1 copied item on the home screen.

I have fixed the broken layout, restored the crushed table, and formatted the code blocks properly. You can copy this entire block and save it as `implementation_guide.md` or append it to your tasks file.

---

# Implementation Guide & Blueprints

## Part 1: The Supabase Blueprint (Backend)

_Goal: Create a realtime bucket that holds your clipboard history._

You need to do specific things in the Supabase Dashboard to make this work.

### 1. Enable Realtime (The Critical Step)

By default, Supabase does not broadcast database changes to apps (to save performance). You must enable this, or your Windows app wont auto-update.

1. Go to Database -> Replication.

2. Click **0 tables** (Source).

3. Select the **`clipboard`** table.

4. Toggle **Insert** and **Update** to **ON**.


### 2. The Store-and-Forward Logic

- **Why Supabase wins here:** You dont need to write server code.

- **The Logic:**

    - **Sender (Windows):** Performs a simple `INSERT` into this table.

    - **Receiver (Mobile/Mac):** Subscribes to `.stream()` on this table.

    - **Cleanup:** (Optional) You can later write a "Cron Job" in Supabase to auto-delete rows older than 30 days to keep it clean.


---

## Part 2: The Windows App Blueprint (Frontend)

_Goal: An invisible "God Mode" app that listens for `Ctrl+Shift+S`._

This is the architecture for your Flutter Windows project.

### 1. The "Invisible Window" Trick

Windows apps usually have a "Title Bar" (Minimize/Close buttons). You need to remove that to get the modern "Spotlight/PowerToys" look.

- **Package:** `window_manager`

- **The Config:**

    - **Startup:** App launches hidden (`hide()`).

    - **Style:** `TitleBarStyle.hidden` (Removes the top bar).

    - **Background:** `Colors.transparent` (Allows for rounded corners).


### 2. The Global Hotkey Logic

This is the core mechanic. The app must listen to the keyboard even when it is minimized to the tray.

- **Package:** `hotkey_manager`

- **The Flow:**

    1. User presses `Ctrl+Shift+S`.

    2. **App Wakes Up:** Calls `windowManager.show()`.

    3. **App Centers:** Calls `windowManager.center()`.

    4. **Focus:** Calls `windowManager.focus()` (Crucial: puts the cursor in your text box immediately).

    5. **Clipboard Read:** It auto-grabs `Clipboard.getData(Clipboard.kTextPlain)` and pastes it into the input field for you to review.


### 3. The System Tray

- **Package:** `tray_manager`

- **Purpose:** Since your window has no "Close" button, you need a way to actually quit the app.

- **Logic:** Right-clicking the tray icon should show a "Quit" option that calls `exit(0)`.


---

## Part 3: The Data Sync Logic

This is how your Windows app talks to the database.

### Sending (The Easy Part)

Dart

```
await supabase.from('clipboard').insert({
  'content': myTextController.text,
  'device_id': 'Windows PC',
});
```
### Receiving (The "Magic" Part)
You don't "fetch" data. You open a live stream.
Dart
```
// This automatically updates the UI whenever a row is added in Supabase
final stream = supabase
  .from('clipboard')
  .stream(primaryKey: ['id'])
  .order('created_at', ascending: false);
```
### Critical Windows Packages Status
|**Feature**|**Package Name**|**Windows Status**|
|---|---|---|
|**Borderless Window**|`window_manager`|✅ **Perfect.** Handles the "hidden" window logic flawlessly.|
|**System Tray Icon**|`tray_manager`|✅ **Perfect.** Adds the icon near your clock.|
|**Global Hotkey**|`hotkey_manager`|✅ **Perfect.** Listens for `Ctrl+Shift+S` globally.|
|**Auto-Start**|`launch_at_startup`|✅ **Essential.** Makes sure your app runs when you turn on your PC.|
### The Table Structure
1. **`id`**: Unique ID for the clipboard item.
    
2. **`content`**: The text you copied.
    
3. **`user_id`**: The person who copied it (You).
    
4. **`device_id`**: Which device sent it (e.g., "Windows PC").
    
5. **`is_public`** _(For Later)_: Boolean. If false, only you see it. If true, your friends see it.