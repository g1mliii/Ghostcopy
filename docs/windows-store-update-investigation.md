# Microsoft Store update delay investigation

Investigated on September 29, 2026. The installed application launches and
works according to the user. The tray regression is patched separately.

**Update, October 1, 2026:** the cause is identified and a fix is in
`windows/explorer_command/surrogate_shutdown.cpp` (#87) - see
[Cause and fix](#cause-and-fix). It is not yet verified on a real Store
update, and the first update to carry it cannot show it; see
[Still to verify](#still-to-verify).

## Verified evidence

- Microsoft Store updated `g1mli.GhostCopy` from package `1.0.10.0` to
  `1.0.16.0`. The installed executable reports app version `1.0.4+16`.
- Store download telemetry reports 5,088,758 bytes and 10,236 ms.
- The final registration operation took 91,687 ms. Its performance summary
  attributes 91,375 ms to an unclassified gap before user registration.
- Four successful `TerminateApplications` events immediately precede
  registration completion. The Store then reports `Completed`, 100 percent,
  `readyForLaunch: True`, and successful completion.
- Windows Error Reporting recorded a `MoAppHang` under the old GhostCopy
  package at that same completion time. The report identifies the actual
  executable as `C:\Windows\System32\dllhost.exe`, with app name
  `COM Surrogate`, and the description `Stopped responding and was closed`.
- An earlier package removal also produced the same COM Surrogate hang
  signatures under GhostCopy package `1.0.12.0`.

Evidence sources: `Microsoft-Windows-AppXDeploymentServer/Operational`
(activity `43a2564b-5051-000b-4dfe-a3435150dd01`, events 603, 9643, 400, 613),
`Microsoft-Windows-Store/Operational`, and the WER report
`56fc0079-cb04-42e2-b3de-8404778671f0`.

## Cause and fix

Confirmed on October 1, 2026, on the 1.0.17 → 1.0.18 update, which behaved
the same as the 1.0.16 one above (register 91,703 ms, a 91,359 ms gap,
registration itself 109 ms):

- Every archived `AppHang_g1mli.GhostCopy_*\Report.wer` back to 1.0.10 names
  `OriginalFilename=dllhost.exe` with hang type `0x200000` (quiesce).
- Right-clicking a file starts that `dllhost.exe` hosting
  `ghostcopy_shell.dll`, inside GhostCopy's package container, and Explorer
  keeps it loaded afterwards. It has no top-level window - COM's own window
  is message-only - and an update closes a package's processes by sending
  end-session messages to their top-level windows. The request went
  unanswered until the update timed out and killed it.
- It is not particular to this DLL. The same machine's WER archive holds
  the same `dllhost.exe` quiesce hang (`0x200000`) for VS Code, OneDrive and
  another packaged app with an Explorer verb: any windowless packaged
  surrogate an update has to close.
- A polite Restart Manager close of that surrogate returns `351`
  (`ERROR_FAIL_NOACTION_REBOOT`): there is nothing in it to ask. The same
  request to `ghostcopy.exe` closed it in 0.1 s, so the app itself was never
  the problem - consistent with the caution above about the runner.

The fix gives the surrogate a hidden top-level window, on its own thread,
that ends the process when asked: on `WM_ENDSESSION` or `WM_CLOSE`, after
letting any send already under way finish (up to 10 s). It runs only in a
`dllhost.exe` with GhostCopy's package identity, and the first activation
does not return until the window exists. Measured locally against the same
polite close: `351` and still running before, `0` in 0.01 s and gone after;
in a real COM surrogate with a client still holding it, the same.

## Interpretation and limits (September 29)

The strongest lead is shutdown of the COM host used by the packaged shell
integration. The installed manifest declares `ghostcopy_shell.dll` in a
`com:SurrogateServer` for the "Send with GhostCopy" context menu. This is an
inference from the manifest and the hung executable: the report does not
provide a thread stack or identify the loaded GhostCopy DLL directly.

The evidence does not establish that the main Flutter window caused the
delay, or that download size, bandwidth, or the build process caused it.
Do not change the runner's shutdown handling on this evidence alone.

A direct native lifetime probe against a temporary copy of the installed
`ghostcopy_shell.dll` passed 1,000 class-factory, command-object, and server-lock
cycles. `DllCanUnloadNow` correctly prevented unloading while references or
locks remained, then returned `S_OK` after release in every cycle. This rules
out a basic reference-count leak along those tested paths, but does not test
Explorer's ownership, COM surrogate teardown, concurrent calls, or MSIX
servicing.

## Still to verify

The update that ships the fix still has to close the *old* version's
surrogate, so it will pause as before. The update after it is the test:

- It should go from 100% to installed without the pause, after a file has
  been right-clicked in Explorer at some point beforehand (otherwise there is
  no surrogate running and nothing is tested).
- In `Microsoft-Windows-AppXDeploymentServer/Operational`, event 613 for
  the register should show no long gap.
- No new `AppHang_g1mli.GhostCopy_*` folder should appear in
  `C:\ProgramData\Microsoft\Windows\WER\ReportArchive`.

If it still pauses, the diagnostics below are the next step.

## Diagnostics (September 29)

Run `installer/windows/collect-update-diagnostics.ps1` while the update is
paused, then run it again after completion. Each invocation saves a new local
JSON report in the temp folder. Use `-Since` to select a narrower event window
and `-OutputPath` to choose a new report file. The script does not upload files,
terminate processes, enable logging, or read GhostCopy's clipboard/history.

The report includes package versions, deployment activity IDs and numeric
timings, selected Store progress/status fields, matching WER executable names,
and a snapshot of GhostCopy processes or COM hosts loading
`ghostcopy_shell.dll`. Raw events, command lines, account identifiers, paths,
and dump contents are excluded. Access failures and bounded event reads are
marked as warnings. A snapshot without a matching host does not rule out an
earlier hang or a host whose modules could not be inspected. Reports contain
timestamps/process IDs and can be reviewed before sharing.

For release preparation, the patch raises the application to `1.0.5+17` and
the MSIX package to `1.0.17.0`, above the installed Store package `1.0.16.0`.

Before submitting that build, check the tray icon directly and from the
notification-area overflow: right-click repeatedly, click away immediately,
then reopen and use Settings and the Spotlight hotkey. The mini menu should
remain a mini menu, click-away should hide it, and Settings/Spotlight should
restore the normal centered window size and resizing. Automated regression
tests cover setup blur, delayed/stale focus callbacks, and drawing a menu while
Flutter's hidden lifecycle suspends ordinary frames; native tray interaction
still needs verification on the rebuilt app.

Reproduce a packaged upgrade on a separate test installation with the
context-menu COM host active and inactive. Capture a stack or wait-chain from
the hung host during the pause, and correlate it with the deployment activity.
Use that result to select a change, then repeat the packaged upgrade and verify
shutdown duration, app launch, syncing, notification activation, and the
context-menu command. Local DLL tests alone do not verify Store update speed.
