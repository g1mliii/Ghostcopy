# macOS resource baseline

Measured September 22, 2026 on the installed Developer ID release 1.0.0 (5),
Apple Silicon, macOS 27.0 (26A428). These are short observations of an existing
user session, not a controlled benchmark or a memory-leak soak test.

| State | CPU | Physical memory footprint | Threads |
| --- | --- | --- | --- |
| Initial idle/background session | Mostly 0.0%; brief 0.4% sample | 83–84 MB | 11–13 |
| Main window visible, settled and untouched | 0.7–0.9%; one 1.5% sample | 119–125 MB | 13–16 |
| User typing/interacting | Samples up to 31.7% | Variable | Variable |

The user confirmed the visible-window state. Initial open-window samples
included typing and must not be treated as idle CPU. The final settled sample
lasted about 30 seconds, with readings every two seconds. Discard top's first
CPU row, which is not an interval reading. Memory here is top's MEM / sample's
physical footprint, not ps RSS; these metrics must not be compared interchangeably.

Native stack sampling found the raster thread waiting in the initial idle
sample. Interaction samples contained text-input and rendering work. The short
measurements do not establish a leak or identify a justified performance fix.
Thread count alone does not measure CPU consumption. The cursor as a cause of
visible-window cost remains unproven; Flutter's macOS TextField already disables
smooth cursor opacity animation by default.

## Repeatable measurement

Find the installed process, then replace PID below with its numeric process ID:

```bash
pgrep -fl '/Applications/GhostCopy.app/Contents/MacOS/ghostcopy'
top -l 16 -s 2 -pid PID -stats pid,cpu,mem,threads,time
sample PID 5 -file /tmp/ghostcopy-sample.txt
```

Measure hidden, visible untouched, and typing/scrolling separately. After opening
the window, allow transitions and history loading to settle. Do not type or move
the pointer over controls during an idle measurement. Confirm that returning to
another app has not hidden GhostCopy. For before/after comparisons, keep the
release mode, clipboard payload, history, settings, and window state consistent.
Run stack sampling separately from the clean CPU interval where possible.

Before pursuing memory reductions, repeat open/hide cycles and a longer idle
session to distinguish retained caches from steadily growing allocations. Before
changing rendering, use a profile build and Flutter frame profiling to identify
which frames and widgets account for the cost. Do not disable clipboard sync or
remove useful caches solely to reduce a thread or memory number.
