# Windows clipboard notification feedback loop

Copying a clip could make both History and Settings scrolling lag, including
dragging the scrollbar. Small text was sufficient, and clearing the composer
did not reset the slow state.

## Cause and repair

`FlutterWindow::FlushOwnedClipboard()` assumed `OleFlushClipboard()` would
release GhostCopy's owner window. On the affected Windows machine, ownership
remained with GhostCopy. The flush advanced the clipboard sequence and emitted
another `WM_CLIPBOARDUPDATE`, which posted another flush indefinitely.

The guard now remembers the sequence **after a successful flush**. Notification
scheduling and execution both skip that completed state. A new sequence still
flushes, including another write from the same process. Failed flushes remain
retryable; an unavailable sequence (zero) is not permanently suppressed.

The faulty ownership assumption was introduced in `450e271` on 2026-09-25.

## Evidence

Passive native input tracing measured:

| Measurement | Before | After |
| --- | ---: | ---: |
| Clipboard-update messages in captured interaction | 113,363 | 2 |
| Maximum mouse-input queue age | 2,969 ms | 16 ms |
| 95th-percentile mouse-input queue age | 16 ms | 0 ms |

The captures differ in duration and are not a throughput benchmark. The
baseline additionally showed 1,913 clipboard sequence increments in about one
second with GhostCopy owning the clipboard throughout; no user copy was
needed to sustain that activity. The user confirmed the guarded build fixed
the lag. Before/after profile builds used byte-identical Dart snapshots.

Flutter layout/raster timings were mostly short because input was delayed
before Flutter received it. Layout, thread-policy and software-rendering
experiments did not resolve the issue and were removed.

Temporary tracing sources are retained under the ignored
`build/scroll-diagnostic-source` directory. Captures are in
`%TEMP%\GhostCopy-scroll-traces`. No tracing hooks or service extensions remain
in the production patch.

## Platform scope

This feedback loop is Windows-specific. A source audit found no equivalent
notification-triggered clipboard flush/write on other platforms:

- macOS: `ClipboardChangeCount.swift` only reads `NSPasteboard.changeCount`.
- Linux: X11 filters this process's owner-change events; Wayland identifies
  own offers. Notifications only update counters and notify Dart; they do not
  rewrite the clipboard.
- iOS/Android: neither uses this runner or OLE flush path. The shared activity
  watcher reads counters and dates changes rather than writing in response.

Only Windows received native runtime verification in this investigation.

## Regression check

The native test checks suppression of repeated self-notifications, a new copy
from the same owner, failure retryability, and sequence zero. After a Windows
Flutter build has configured CMake:

```powershell
cmake --build build/windows/x64 --config Release --target clipboard_flush_guard_test
./build/windows/x64/tests/Release/clipboard_flush_guard_test.exe
```

The target is excluded from ordinary builds and its binary goes outside the
app bundle.
