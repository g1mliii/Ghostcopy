# iOS resource baseline

Measured September 24, 2026 on an iPhone 15 Pro, iOS 27.0, with a release
build of 1.0.0 signed for development (needed so Instruments can read the
process; the code is the same as a distribution build). Short observations of
a real session, not a soak test. Memory is the physical footprint, the number
iOS weighs when deciding what to terminate.

| State | CPU (one core) | Memory | Wakeups/s |
| --- | --- | --- | --- |
| Foreground, idle on the history list | 0.02–0.08% | 115–117 MB | 0.5–0.7 |
| Coming back to the foreground | ~200 ms of work, then idle | peak 153 MB, settles at ~116 MB within 2 s | - |
| Composer focused, keyboard up, not typing | **1.3%** (was 21%) | ~157 MB | **~38** (was ~247) |
| Typing | ~25% while keys are pressed (was 37%) | 157–184 MB, returns after | ~125 |
| Keyboard closed again | ~0% | 122–135 MB | ~0.5 |
| Background (suspended) | 0.00% | 72.8 MB | ~0 |

For comparison, the Mac (`docs/macos-performance.md`) sits at 83–84 MB hidden
and 119–125 MB with the window open. Most of the iOS footprint is Flutter
itself - the engine, Dart runtime, fonts and shaders - plus Firebase and the
Supabase client; a native app would sit lower.

## What changed because of this

- **Cursor.** The iOS text cursor fades by animating its opacity, which asks
  for a frame continuously - up to 120 a second on ProMotion - for as long as
  a text field has focus. The composer cost 21% of a core with nothing typed.
  `cursorOpacityAnimates: false` and a `RepaintBoundary` on the composer and
  the history search box brought it to 1.3%. Only iOS fades by default; macOS,
  Windows and Android already blink.
- **Keyboard.** There was no way to close it and stay on the screen. A tap
  outside either field and dragging any scroll view now dismiss it.
- **Reopening.** Every resume showed the loading spinner in place of the clips
  while the history reloaded, so the list flashed out and back. The reload is
  now silent when clips are already on screen (iOS and Android).

## Not traced, and why that is acceptable

The recorder hung whenever a process started on the phone mid-recording - the
app waking, the share extension launching - so three scenarios were checked
against the code instead:

- **Push while in the background.** The push carries no `content-available`,
  the app declares no background modes, and there is no Notification Service
  Extension. iOS shows the notification itself and GhostCopy stays suspended:
  a push costs the app nothing until it is tapped. Three test pushes were
  delivered while the app sat suspended.
- **Share extension.** Photos from the Photos app arrive as a file URL, which
  `receive_sharing_intent` copies into the App Group container without
  decoding it; its preview image is only drawn in its compose sheet, which
  GhostCopy skips. A full-resolution photo stays far below the ~120 MB
  extension limit. An in-memory image (a screenshot shared from markup) is
  written out as PNG - screenshot-sized.
- **Scrolling the history.** Not measured.

## Open: typing and history-scroll lag (reported 2026-11-10)

Two reports from use on a real iPhone, neither traced yet:

- **Typing in the composer feels laggy.** Nothing in the composer runs per
  keystroke in Dart (`onChanged` only clears a send error; the length check is
  a controller listener), and Sentry holds no iOS hang or slow-frame events
  for the last 30 days. The table above already shows ~25% of a core while
  keys are pressed, so the question is whether frames are being missed, and
  on which thread.
- **Scrolling the history lags after copying a clip, and recovers after the
  app sits idle for a while.** Not reproduced from the code. Scrolling was
  never measured (see above). Still to confirm: whether this is the phone's
  history list or the desktop history panel.

A TestFlight build cannot be traced: it is distribution-signed, so neither
DevTools nor Instruments can attach. It is still worth trying there first -
lag in TestFlight is lag in a release build, not a debug-build artefact.

### Capture

On the Mac, phone plugged in and unlocked. Profile, not debug: a debug build
is slow enough to invent lag that is not there.

```bash
flutter devices
```

```bash
flutter run --profile -d <device-id>
```

Open the DevTools link it prints, go to Performance, and turn on "Track
widget builds". Record each of these as its own short capture, so the frames
in one cannot be blamed on another:

1. **Typing, short text.** Focus the composer, type two ordinary sentences.
2. **Typing, long text.** Paste a few thousand characters, then type at the
   end. Handwriting input is switched off above 2,000 characters, so the two
   cases take different paths.
3. **Scroll, before.** Fresh launch, scroll the history up and down for ten
   seconds without tapping anything.
4. **Scroll, after a copy.** Tap a text clip to copy it, wait for the toast
   to go, scroll for ten seconds.
5. **Scroll, after idle.** Leave the app untouched until scrolling feels
   normal again, note how long that took, and record ten more seconds.

For each capture note the slow frames (red bars) and whether the time is in
UI (Dart: build, layout, paint) or Raster (GPU). Select the worst frame and
export it, or screenshot the flame chart. The difference between captures 3
and 4 is the one that matters for the scroll report: whatever is on screen or
running in 4 that is not in 3 is the suspect.

If DevTools shows nothing slow but it still feels wrong, the cost is outside
Flutter (keyboard, haptics, the pasteboard). Use the `xctrace` recipe below
with the `Time Profiler` template in place of `Activity Monitor`, against a
release build signed for development.

### Results

Fill in after capturing.

| Capture | Build | Slow frames | Worst frame (ms) | UI or Raster | What was in the worst frame |
| --- | --- | --- | --- | --- | --- |
| 1. Typing, short | | | | | |
| 2. Typing, long | | | | | |
| 3. Scroll, before | | | | | |
| 4. Scroll, after copy | | | | | |
| 5. Scroll, after idle | | | | | |

Time for scrolling to recover after a copy:

Device and iOS version:

Does it also happen in the TestFlight build:

## How it was measured

```bash
# Wake the device tunnel first; without it xctrace often times out.
xcrun devicectl device info ddiServices --device <UDID>
# Address the phone by name - by UDID it "timed out waiting to boot".
xcrun xctrace record --device "iPhone (27.0)" --template 'Activity Monitor' \
  --all-processes --time-limit 60s --output run.trace
xcrun xctrace export --input run.trace --xpath \
  '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]'
```

The process is `Runner` (the share extension is `ShareExtension`). The export
de-duplicates values with `id`/`ref` attributes, which have to be resolved;
CPU is best taken from the `cpu-total` delta rather than the per-sample
`cpu-percent`, which is empty on the first sample. Keep recordings to about a
minute, start them before the user acts, and confirm "Starting recording" in
the output before asking for the action - a hung recording holds kperf on the
phone and the next one fails with "could not lock kperf" until it is killed.

After shipping, Xcode Organizer > Metrics gives memory, battery, launch time,
hangs and terminations from real TestFlight and App Store users.
