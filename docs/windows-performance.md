# Windows resource baseline

Measured 25 September 2026 on the **installed MSIX package** 1.0.0.9
(`g1mli.GhostCopy_1.0.0.9_x64__41asz506sbn22`), running from
`C:\Program Files\WindowsApps`, on Windows 11 10.0.26200 with 16 logical
processors. Like the macOS baseline, these are short observations of an
ordinary session - not a controlled benchmark and not a leak soak test.

Taken from the package rather than a `build/` copy on purpose: that is what a
Store user runs, and it is the only build with package identity, so the
startup task and the COM surrogate are in play.

| State | CPU | Working set | Private bytes | Threads | Handles |
| --- | --- | --- | --- | --- | --- |
| Idle, hidden, **before** the working-set trim | 0.00-0.05%, avg 0.01% | 107.2-107.3 MB | 108.1-109.1 MB | 53-54 | 1339-1342 |
| Idle, hidden, **after** the trim | 0.00-0.05%, avg 0.01% | 9.4-10.6 MB | 121.1-122.3 MB | - | - |
| Spotlight open, settled, untouched | 0.00-0.10%, avg 0.04% | 111.5-114.7 MB | 100.8-112.9 MB | 51-55 | 1333-1346 |

Reopening the Spotlight from the trimmed state took 12, 16 and 42 ms across
three attempts - the pages come back as soft faults from the standby list, so
nothing is re-read from disk.

Fifteen samples two seconds apart in each state, after letting it settle.
CPU is the share of the whole machine, the way Task Manager reports it:
process CPU-time delta over wall time over 16 logical processors. A
single-core-saturating thread would read 6.25% here, not 100%.

## What these say

**Sleep Mode holds.** Hidden, the app is at zero CPU - eleven of fifteen
samples were exactly 0.00% and the largest was 0.05%. Whatever the pause
machinery costs, it is below what this method can measure.

**The 107 MB was never the caches.** Of 182.4 MB mapped across 122 modules,
44.8 MB is the GPU driver (`amdxx64.dll`) and 20.5 MB the Flutter engine.
Nothing the app caches is in that number, which is why clearing every image on
hide reclaimed about 5 MB - and why hidden and open measured nearly the same.
The window was never the expensive part; the floor was.

**So the trim, not the clearing, is what moves it.** `trimWindowsWorkingSet`
asks Windows to stop keeping those pages resident when the app goes idle. It
runs 2s after hiding, and 8s after a startup that never shows a window -
because a copy launched at login and left alone never hides, and that is the
state this app spends most of its life in. Watched over a launch: 101.3 MB at
5s, 1.9 MB at 10s, settling near 10 MB.

Note what did **not** change: private bytes are unmoved, and read slightly
higher afterwards. This is not the app needing less memory. It is the app not
holding physical pages it is not using, which the OS can then give to
something else.

**The window is nearly free once settled.** Open and untouched it averages
0.04%, about 4 MB more working set. That is the cost of a rendered surface,
not of ongoing work.

**Private bytes at the open state are not a typo.** The range there
(100.8-112.9 MB) is both wider than idle's and *lower* at the bottom, which
memory that only grew could not be. Showing the window reallocates rather than
adding: the low sample lands while something has been released and not yet
reused. It is recorded as measured rather than smoothed, and it is a reason to
treat the open-state figure as a range and not a number.

## What they do NOT say

**Not comparable with `docs/macos-performance.md`.** That one reports top's
physical footprint and macOS thread counts; this reports Windows working set,
private bytes and Windows thread counts. The 53 threads here against 11-13
there is an accounting difference between two operating systems and the
runtimes they load, not a regression - neither figure measures CPU, and
putting them in one sentence would invite exactly that mistake.

**No interaction figure.** The macOS baseline has one, taken while typing,
and this does not. Do not infer the cost of typing, scrolling or a paste from
the settled numbers above.

**Nothing about leaks.** Two thirty-second observations cannot distinguish a
retained cache from a steadily growing allocation. Before chasing memory,
repeat open/hide cycles and take a long idle session.

## Repeating it

`MainWindowHandle` is 0 for this app even when the Spotlight is up - the
window is frameless - so it cannot be used to tell the two states apart.
Confirm visibility by enumerating the process's windows and checking
`IsWindowVisible`; the Spotlight is the 500x400 one. Check before and after
a measurement, because focusing another app can hide it midway and quietly
turn an open-state sample back into an idle one.

```powershell
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$p = Get-Process ghostcopy
$prev = $p.CPU; $prevT = Get-Date
1..15 | ForEach-Object {
  Start-Sleep -Seconds 2
  $q = Get-Process -Id $p.Id; $now = Get-Date
  '{0}%  ws={1}MB  threads={2}' -f `
    [math]::Round((($q.CPU-$prev)/($now-$prevT).TotalSeconds/$cores*100),2),
    [math]::Round($q.WorkingSet64/1MB,1), $q.Threads.Count
  $prev = $q.CPU; $prevT = $now
}
```

A second launch is the easiest way into the open state: the running instance
treats it as the user asking for the app and shows the Spotlight, so no hotkey
is needed.

```powershell
Start-Process explorer.exe 'shell:AppsFolder\g1mli.GhostCopy_41asz506sbn22!ghostcopy'
```

For a before/after comparison keep the build, the history, the clipboard
payload and the settings the same, and do not touch the pointer or keyboard
during an idle interval.
