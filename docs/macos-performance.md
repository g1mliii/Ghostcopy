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

## Hourly local monitoring (no AI)

`tools/profile_macos_resources.py` records three two-second CPU/physical-memory
intervals from the running app per run (installed or an isolated test build). `tools/install_macos_resource_monitor.py`
installs a user LaunchAgent with a 3,600-second interval and one initial sample.
The job exits between runs, runs at background priority, and never opens or
restarts GhostCopy. It uses Python's standard library and macOS `ps` / `top`,
without Codex, model calls, or network requests. The previous Codex hourly
heartbeat was paused when this LaunchAgent was installed.

```bash
python3 tools/install_macos_resource_monitor.py
launchctl print gui/$(id -u)/com.ghostcopy.resource-monitor
python3 tools/install_macos_resource_monitor.py --uninstall
```

The installer copies the sampler to
`~/Library/Application Support/GhostCopy/monitor/`, so changing branches or
moving the checkout does not interrupt it. Re-run the installer after editing
the sampler. It uses the current Python interpreter; reinstall if that
interpreter is removed. The job runs in the logged-in user's session; sleeping
or logged-out time is not continuous coverage.

Records are stored in `~/Library/Logs/GhostCopy/performance/resources.jsonl`.
At 2 MiB the log rotates, keeping one previous file. Each record contains the
sample timestamp, app path, process lifetime, build, CPU, physical memory, and
thread counts. Comparing different app paths/builds is not a like-for-like trend. Missing or ambiguous processes are recorded as skipped states;
measurement failures record only an error type. No clipboard contents are read.
Visibility and activity remain `unknown`: low CPU alone does not establish idle.
These short hourly samples support trend inspection and can miss brief spikes;
they do not automatically diagnose leaks or send notifications.

## September 22 optimization follow-up

The following changes are covered by targeted regression tests, separately from
the installed-app observations above:

- Thumbnail codecs are disposed after extracting their frame. The decoded image
  is owned immediately when decoding finishes, so unmounting before a
  `FutureBuilder` renders it cannot orphan the native image. Superseded decodes
  dispose their results, and obsolete downloads are ignored before decoding.
- Plain-text detection no longer notifies the entire Spotlight window after
  every typing pause when the preview type is unchanged. Twenty edits produce
  one notification, with another notification when clearing the input. Rich
  preview changes still notify; results for obsolete input are ignored.
- Clipboard reads/uploads and history polling each allow only one operation in
  flight. Four timer ticks during a deliberately delayed request produce one
  request rather than four. A failed request releases the guard so the next
  tick retries. Normal idle intervals and sync settings are unchanged.

These checks measure resource ownership and repeated work, not a percentage
reduction in whole-app CPU or RSS. GhostCopy was closed during this follow-up;
a matched installed-release before/after CPU and physical-memory comparison
remains to be collected. Source changes are not automatically installed into
`/Applications/GhostCopy.app`.

## Typing and original-quality transfer validation (September 23)

Typing regression tests now cover 100 edits spaced 100 ms apart: no detection
runs during the burst, one runs after the final 300 ms pause, and no further
detection or window notifications occur during 30 seconds of simulated idle.
Selection-only changes do not restart detection. Color previews still refresh
when their value changes. These are deterministic work-count checks, not live
CPU measurements. The rebuild fix removes work after pauses; it does not prove
that rebuilds caused the earlier CPU sample while continuously typing.

A short native sample of the installed app showed 12 threads and 0.0% CPU.
The main event loop, raster/IO threads, and Dart workers were waiting. UI state
could not be inspected during this run, so this is not a visible-window or
active-typing benchmark. More sleeping threads do not imply a CPU leak.

Thumbnail decoding is shared by macOS, Windows, iOS and Android. Resizing the
rendered `ui.Image` does not replace the bytes in the repository's media cache.
Both **Save to Computer** and drag-out read `downloadFile`; saving writes those
bytes directly, and dragging offers a temp file containing those same bytes.
The drag fallback filename now uses a real extension such as `.png` or `.pdf`.

The quality audit found separate upstream reductions and removed them:

- Repository image uploads no longer resize to 1920 pixels or re-encode JPEGs.
- Gallery selection uses the existing file picker's no-compression path. Its
  iOS implementation copies the original asset file representation; Android
  skips image compression. This also avoids the old 2048-pixel picker cap and
  iOS image-picker re-encoding. HEIC/HEIF/AVIF are retained as original files
  with the correct MIME type when the app has no image-preview support.
- Newly inserted encrypted media retain `isEncrypted` in the returned item,
  so an immediate download/export decrypts them instead of treating ciphertext
  as the image. Existing history rows already stored that flag correctly.

Byte-for-byte upload/download tests cover PNG and JPEG wider than the old
1920-pixel cap, GIF, and PDF, with encryption enabled and disabled. Mobile
selection tests check zero-compression requests and preservation of PNG/HEIC
bytes. These are mocked storage/picker boundary tests, not physical-device
end-to-end tests. The existing file-size limit still applies. Previously
compressed uploads cannot recover their original detail; send them again.

For manual validation, use a newly sent high-resolution image and a document.
Save each to the desktop and drag each to the desktop; compare original and
exported files with `shasum -a 256`. Matching hashes confirm identical bytes.
Then compare settled visible idle, ordinary typing, and stopped-typing CPU
separately. Let startup/history loading settle before taking readings.

The local Rust build of `super_native_extensions` failed with E0463 on macro
crates. The manual-test release uses Cargokit's supported
`use_precompiled_binaries: true` option; Cargokit verifies the dependency's
precompiled binaries with its bundled public key. The temporary config is
removed after building. The app is built in the isolated
`performance-validation` checkout to avoid generated-file collisions with
other work in the main checkout.

The final Mac release was built and launched from
`/Users/subaigsuri/.codex/worktrees/performance-validation/ghost/build/macos/Build/Products/Release/ghostcopy.app`.
It leaves the installed `/Applications/GhostCopy.app` unchanged. The hourly
script now discovers either running bundle and records its path; multiple
instances are marked ambiguous rather than combining unrelated measurements.
The updated LaunchAgent sampler was installed and its seven offline tests pass.

## September 23 manual typing sample

The user manually typed in the isolated release build (PID 77107). The recording
ran from 12:04:18 to 12:05:06 America/Toronto. The user confirmed they continued
typing rather than stopping for the requested final 15 seconds. Excluding top's
initial baseline, CPU ranged from 3.5–14.2%, generally 9–14%, with 14–16 live
threads. A five-second native sample overlapped the early recording; this is
diagnostic evidence, not a clean before/after benchmark.

The release App.framework dSYM UUID matches the running binary
(B4485C2E-FD4C-5B51-38E6-CC8D0F725672). Resolving its sampled addresses with atos
identified Flutter text editing, RenderEditable layout, render-object layout and
painting, and widget rebuilding. Native AppKit text-input/layout also appears.
The Dart worker waited in 2878 of 2879 samples; engine worker threads were
waiting throughout. The raster thread waited in 2826 of 2879 samples. These
wall-clock stack counts do not directly measure CPU percentages, but do not
support a busy background-worker explanation for this particular typing sample.
Many short-lived CVDisplayLink thread identities occur while live thread count
stays bounded. Flutter's installed engine starts/stops its display link around
frame requests; the thread identities alone do not demonstrate a thread leak or
establish the dominant CPU cost.

A later non-interacting recording settled to 0–0.3% CPU and 11–13 threads,
approximately 70–71 MiB physical memory. Window visibility was not independently
confirmed, so this is not a verified visible-idle baseline. A first attempted
stop interval still had 4.8–16% CPU and cannot be labeled idle without activity
confirmation. The earlier 31.7% spike was not reproduced in the confirmed typing
recording. This does not prove the reported issue fixed: input length/rate,
window state, and profiling overhead were not matched against that older run.

Local raw diagnostics: /tmp/ghostcopy-typing-controlled.txt,
/tmp/ghostcopy-typing-active-stacks.txt, /tmp/ghostcopy-typing-symbolicated.txt,
and /tmp/ghostcopy-settled-followup.txt. Stack samples record function names and
addresses, not text-box contents.

## Updated main integration

Rebased the integration branch onto origin/main at 64735a7 (PR #24). Resolved
documentation/website conflicts using the previously merged state at 005aa9f;
the committed tree is byte-identical to that state. Restored all 17 uncommitted
performance/test/tool files byte-for-byte. The combined tree passes 215 Flutter
tests (one skipped), seven monitor tests, static analysis, and diff whitespace
checks. Earlier typing measurements above predate this integration; they are
not measurements of the rebuilt profile app. No remote history was rewritten.

## Rebased profile build: manual typing capture

The user performed a final 20-second typing pass in the rebased profile build
(PID 8497). Dart CPU sampling and Dart/Embedder/GC timeline tracing were enabled.
The capture contains 2,000 CPU samples and 345 complete UI/raster frames.

| Span | Median | p95 | Maximum |
| --- | --- | --- | --- |
| UI frame | 1.970 ms | 2.941 ms | 3.219 ms |
| Widget build | 0.479 ms | 0.621 ms | 0.674 ms |
| Layout | 0.716 ms | 1.213 ms | 1.405 ms |
| Paint | 0.415 ms | 0.622 ms | 0.713 ms |
| Raster draw | 1.066 ms | 1.270 ms | 1.766 ms |

No captured UI or raster span exceeded 16.67 ms. These spans do not measure
end-to-end keyboard latency or every possible OS scheduling delay. CPU readings
ranged from 14.6–29.8%, with 17–19 live threads. Profile-mode measurements are
not directly comparable to the earlier release run: tracing itself contributed
182 of 2,000 self samples in timeline reporting. Native text layout contributed
168 self samples; rendering/layout, frame scheduling and platform input dominate
the sampled paths. The application's updateContent/debounce/controller-listener
path appears in just one shared sampled stack. This supports focusing on the
framework text/rendering path rather than blaming background workers or heavy
application work on every key. It does not prove the original larger spike's
cause or justify disabling text editing features.

In the preceding stop interval, after the user reported stopping and was asked
to keep the window visible, CPU was mostly 0.8–1.0%, with one 2.4% interval and
13–17 threads. Visibility was user-directed, not independently inspected. The
first CPU capture attempt failed because the VM profiler was disabled; its
frame timeline was recovered, then profiling was enabled for the successful
final pass. Both timeline tracing and CPU sampling were disabled afterward.

No additional typing-code change was made from this measurement: the sampled
frames are comfortably within budget and there is no demonstrated runaway
typing loop. Raw diagnostics remain local under /tmp/ghostcopy-dart-cpu.json,
/tmp/ghostcopy-frame-timeline.json, /tmp/ghostcopy-profile-final-typing-top.txt,
and /tmp/ghostcopy-profile-stopped-top.txt. The current app remains a profile
build; use a release build for everyday resource comparisons.

## CPU-only follow-up and rejected decoration change

A further manual 20-second typing capture disabled recorded timeline streams
and enabled only the Dart CPU sampler. It captured 1,143 samples. Native macOS
stack sampling ran for ten seconds at 5 ms intervals alongside it. Process CPU
was 7.6–19.6% with 16–18 live threads; sampling still adds overhead.

The leading Dart leaf was _NativeParagraph._layout (72 samples), called through
TextPainter.layout and RenderEditable.performLayout. JSONMessageCodec.encodeMessage
appeared in 104 inclusive samples, largely success-envelope encoding for native
method-channel replies. GhostCopy's controller listener, updateContent and
debounce occurred in two shared sampled stacks; content detection occurred in
one. These overlapping counts are not additive percentages of process CPU.
Native stacks also show FlutterTextInputPlugin.updateTextAndSelection doing
AppKit text/selection work. The raster thread and Dart/engine workers spent
most wall-clock samples waiting. This further narrows work to the framework's
editing/layout and native input bridge, rather than a busy app callback.

A standalone release experiment applied identical controller text edits to the
existing Material decoration, a simple external decoration, and a bare field.
The first Material pass used 0.93 CPU seconds over 8.20 seconds, but subsequent
Material passes both used 0.46 seconds over 8.18 seconds. Simple decoration used
0.45–0.46 seconds and bare fields 0.44–0.46 seconds. No meaningful steady-state
CPU reduction was demonstrated, so the proposed decoration replacement was
rejected and not added to production. Window focus was not logged in that first
experiment; its initial higher reading cannot be attributed reliably to warmup.

A revised native-keyboard experiment logs key delivery, active/key/visible window
state, and inactive ticks. Its initial runs delivered all 80 expected characters
but reported every tick inactive and the window occluded. These runs are not
valid foreground typing comparisons. The experiment was stopped pending a
visible display; no production code was changed from those results.

Diagnostic traces, benchmark source, and results are preserved under
~/Library/Logs/GhostCopy/performance/typing-investigation-2026-09-24/.
The standalone benchmark lives in /tmp/ghostcopy_typing_bench and has no
clipboard/network application logic. It is not a GhostCopy production change.
The native variant sends keyDown/keyUp directly to its own FlutterViewController
and checks the resulting text length; it does not inject events into other apps.

Upstream issue https://github.com/flutter/flutter/issues/189722 describes a
sustained keyboard redispatch loop after Accessibility-injected events. That
pattern does not match the captured physical typing sessions here, which settle
after typing stops; it is not being treated as their cause.

## Foreground native-keyboard comparison (September 24)

Completed all nine release-mode phases with the benchmark window active, key,
and visible on every injected keystroke (zero inactive ticks). Every phase
received all 80 expected characters. Each phase measured about 8.22 seconds
after 15 warmup keys; the three configurations were interleaved/reversed to
reduce order effects. CPU percentage is 100 × process CPU-time delta / elapsed
wall time, with no Dart profiler or recorded frame timeline enabled.

| Configuration | CPU across three phases | Median |
| --- | --- | --- |
| Material decoration, default autofill | 13.63%, 13.39%, 13.38% | 13.39% |
| Same field, autofill disabled | 13.75%, 13.99%, 13.14% | 13.75% |
| Bare TextField, no decoration | 14.47%, 14.35%, 14.47% | 14.47% |

Neither candidate demonstrated a CPU reduction, so neither was applied to
GhostCopy. The bare field generated more frames in this workload; removing
decoration is not automatically more efficient. A minimal Flutter app with no
GhostCopy services reproduces approximately the reported typing CPU range.
Together with the real typing stacks, this points toward framework/native
editing overhead and provides no evidence for an app-specific runaway loop.

This is a controlled native-key-dispatch comparison, not a physical-keyboard
benchmark of GhostCopy: the harness invokes its own FlutterViewController's
keyDown/keyUp handlers through an extra method channel, adds one character
every 100 ms, starts with a fixed text payload, and samples FrameTiming. The
extra method-channel work is shared by all variants. Absolute CPU percentages
should therefore not be treated as an exact decomposition of GhostCopy's
physical-keyboard CPU use. No comparison with an AppKit-native editor was made.

All results are preserved in
~/Library/Logs/GhostCopy/performance/typing-investigation-2026-09-24/native-benchmark-visible.jsonl.
The standalone test app exited normally on completion.
