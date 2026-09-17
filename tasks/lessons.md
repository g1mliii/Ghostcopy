# Lessons Learned

This file captures mistakes, failure modes, and prevention rules discovered during development.

## Format

Each entry should include:
- **Date**: When the lesson was learned
- **Failure Mode**: What went wrong
- **Detection Signal**: How it was discovered
- **Prevention Rule**: How to avoid it in the future

---

## Entries

<!-- Add lessons below as they are discovered -->

### 2026-09-14 - Branch comparison read stale remote refs

- **Date**: 2026-09-14
- **Failure Mode**: Compared `main` to `modernize-deps` with `git log main..modernize-deps`
  and reported 76 commits of work as unmerged, recommending a merge. The work had
  already been merged and shipped as PR #3; the branch's remote had been deleted.
  The comparison used local refs that predated all of it.
- **Detection Signal**: The user said "it should already be merged". A `git fetch --all
  --prune` then showed `origin/modernize-deps` deleted - the signature of a merged and
  cleaned-up PR branch - and `origin/main` ahead of local `main` by 77 commits.
- **Prevention Rule**: Run `git fetch --all --prune` *before* any branch comparison that
  informs a recommendation, and compare against `origin/<branch>`, never bare local refs.
  A deleted upstream branch means merged-and-cleaned, not abandoned. Local refs are a
  snapshot from whenever the last fetch happened, and the session's opening git status is
  explicitly "a snapshot in time" - never treat either as current.


### 2026-09-14 - Shipped a waitlist whose signup path could never have worked

- **Date**: 2026-09-14
- **Failure Mode**: Added `Prefer: resolution=ignore-duplicates` to the beta waitlist POST
  so a repeat signup would answer 201 rather than 409, closing an email-enumeration
  oracle. The table is deliberately insert-only with no SELECT policy for `anon`. Those
  two facts are incompatible: PostgREST compiles that header to `ON CONFLICT DO NOTHING`,
  and Postgres needs SELECT on the arbiter index's columns to evaluate a conflict target.
  Every signup failed with 42501, surfaced as HTTP 401. It went through review, CI and a
  production deploy, because the security properties were all tested and the happy path
  was not.
- **Detection Signal**: Probing the deployed endpoint after the deploy. The negative tests
  (cannot read the list, cannot reach `clipboard`, bad input rejected) all passed, and the
  one positive test returned 401. Isolating it by varying only the `Prefer` header showed
  a bare insert returning 201 and the same insert with `resolution=ignore-duplicates`
  returning 401.
- **Prevention Rule**: A security control that changes how a request is executed has to be
  tested on the success path, not only on the paths it is meant to block - "everything I
  tried to break was blocked" and "the feature works" are different claims, and only the
  first was ever verified here. More specifically: privilege-restricted tables and
  `ON CONFLICT` do not mix, so deduplicate in a `BEFORE INSERT` trigger that returns NULL
  (which also keeps the 201 uniform and closes the same oracle) rather than in the
  request. Related: an RLS `WITH CHECK` failure returns 42501/401, not the 400 a column
  constraint gives, so tightening a policy can silently change the status codes a client
  branches on.


### 2026-09-16 - Called a build green because the .app directory existed

- **Date**: 2026-09-16
- **Failure Mode**: Reported "the build succeeded" to the user after seeing
  `build/ios/Debug-iphonesimulator/Runner.app` on disk. The build was still
  running. Xcode creates the bundle directory early and fills it as it goes -
  at that moment it held only `Frameworks`, with no binary and no `Info.plist`.
  The install then failed with "Missing bundle ID", which is what a half-built
  bundle looks like, not a configuration problem.
- **Detection Signal**: `xcrun simctl install` failed on a build I had just
  announced as finished. The build log was 0 bytes and `xcodebuild` was still
  in `ps`.
- **Prevention Rule**: A build artifact existing is not a build succeeding.
  Confirm the *process* finished and read its exit status before reporting -
  for a backgrounded build that means the completion notification or an
  explicit `ps` check, never `find`-ing the output path. Related trap in this
  session: `cmd | tail` reports tail's exit status, so a failing build shows
  `EXIT=0`. Use `${PIPESTATUS[0]}` or check the log text for the failure line.


### 2026-09-16 - Dismissed the load-bearing half of a working fix as cargo cult

- **Date**: 2026-09-16
- **Failure Mode**: iOS pods failed on Xcode 27 with `IPHONEOS_DEPLOYMENT_TARGET
  is set to 13.0`. `macos/Podfile` already solved the same problem two ways: a
  project-level loop and a per-target, per-configuration loop. I copied the
  project-level loop, explicitly declined to copy the per-target loop as
  "mobile_scanner-specific cargo cult", and it did not work. The per-target loop
  was the part that mattered. Two further attempts failed because I had also
  misidentified *where* the 13.0 lived: my script printed those configurations
  as "(project-level)" merely because their block had no `PRODUCT_NAME`, and I
  believed the label instead of checking which configuration list owned them.
  They belonged to `PBXAggregateTarget "Flutter"`.
- **Detection Signal**: The setting read 16.0 in memory during `post_install`
  and 13.0 on disk afterwards - which should have prompted "I am editing the
  wrong object", not "CocoaPods is overwriting my save". Resolving the owning
  configuration list by UUID found the aggregate target immediately.
- **Prevention Rule**: When a sibling platform in the same repo already solves
  the identical problem, port its fix whole and only then remove parts that are
  demonstrably unnecessary - "this looks unrelated" is a hypothesis, not a
  finding. And when locating a setting in a pbxproj, resolve the owning target
  or configuration list by UUID; absence of a field like `PRODUCT_NAME` is not
  evidence of project scope. Root cause worth remembering: Flutter's generated
  podspec pins `ios.deployment_target = '13.0'` and podhelper only strips values
  strictly below 13, so exactly 13.0 survives into a toolchain that rejects it.


### 2026-09-17 - Theorised three times from source when the device log had the answer

- **Date**: 2026-09-17
- **Failure Mode**: iOS launched to a blank white screen. I produced three
  confident diagnoses from reading code, and all three were wrong: first the
  `NSExtension` key in the app Info.plist (a real bug, but not this one),
  then `SystemChrome.setEnabledSystemUIMode` throwing `MissingPluginException`,
  then the same call hanging on an unanswered platform channel. The actual
  cause was in `log show` the whole time: `Application failed to launch:
  UIScene life cycle is required for apps built with this SDK`. Building
  against the iOS 27 SDK makes UIScene mandatory, so UIKit refused to launch
  the app - which is why every Dart log line looked healthy. Dart was running
  fine; it had no window to draw into.
- **Detection Signal**: Instrumenting `main()` with prints either side of the
  suspect call disproved the hang outright - `setEnabledSystemUIMode` completed
  in 5ms and `runApp` was reached. Every theory had predicted Dart stopping
  early; Dart was never the problem.
- **Prevention Rule**: For a native launch or rendering failure, read the
  device log *first* - `xcrun simctl spawn <udid> log show --predicate 'process
  == "Runner"' --last 5m`. Dart-level logs only cover the Dart side, and a
  clean Dart log with no UI is positive evidence the problem is native. Reading
  source generates hypotheses; only the log distinguishes between them. Second
  rule: after a fix, screenshot again before concluding it failed - the
  migration had actually worked, and I called it a "second independent bug"
  because I captured the screen before Flutter's first frame landed.

