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


### 2026-09-17 - Changing Keychain accessibility orphaned the existing passphrase

- **Date**: 2026-09-17
- **Failure Mode**: Gave FlutterSecureStorage an explicit
  `IOSOptions(accessibility: KeychainAccessibility.first_unlock)` so a
  push-woken background isolate could read the encryption key while the phone
  was locked. The reasoning was sound and the locked-phone bug is real. What I
  missed is that accessibility is part of a Keychain item's attributes, so
  changing it orphans every item already written under the old value: the read
  no longer matches and returns nothing, and the subsequent write collides with
  the item that is still there. On a real upgrade that locks a user out of
  their own encrypted clips permanently - the old passphrase is unreadable and
  a new one cannot be stored.
- **Detection Signal**: Two contradictory lines in the same run -
  `No existing passphrase found` followed by
  `Failed to set passphrase: ... Code: -25299 ... The specified item already
  exists in the keychain.` A read miss and a write duplicate for the same key
  can only both be true when the query attributes changed. Caught on a
  simulator that looked like a clean install, because simulator Keychain items
  survive app uninstalls.
- **Prevention Rule**: Never change the accessibility (or any query attribute)
  of an existing secure-storage key without a migration: read with the OLD
  options, delete, then write with the new ones, and ship that migration before
  or alongside the change. More generally - a storage change that alters how a
  key is *addressed* is a data migration, not a configuration tweak, and needs
  to be tested against a device that already holds the old data rather than a
  fresh one. Reverted rather than fixed forward at the time, because the
  original bug it addressed only affects a locked phone while the regression
  destroys access to encrypted data outright.
- **Resolved 2026-09-18**: fixed forward, as a migration this time -
  `lib/services/impl/keychain_accessibility.dart`, with tests that model the two
  Keychain behaviours that caused this (an item is identified by service and
  account, so old and new cannot coexist and an add collides; a read filters on
  accessibility, so the old item is invisible). The rule above stands: what made
  it safe was the migration, not the constant.



### 2026-09-17 - Installed a Flutter debug build on device and called it a crash

- **Date**: 2026-09-17
- **Failure Mode**: Built the app for the physical iPhone with `xcodebuild
  -configuration Debug` and installed it with `devicectl`, then told the user
  it was ready to open. Tapping the icon killed it instantly (signal 11). I had
  assumed iOS Flutter debug builds launch standalone and that only hot reload
  needed the tooling attached. They do not: since iOS 14 a debug build cannot
  create a FlutterEngine without `flutter run` or Xcode driving it, because JIT
  is unavailable to a home-screen launch. The binary was fine; the
  configuration was wrong for how it was going to be started.
- **Detection Signal**: `devicectl device process launch --console` printed the
  engine's own explanation - "Cannot create a FlutterEngine instance in debug
  mode without Flutter tooling or Xcode ... Alternatively profile and release
  mode apps can be launched from the home screen" - immediately before
  "App terminated due to signal 11". The signal alone looks like a native crash
  in the changed code and sent me looking at the wrong thing first.
- **Prevention Rule**: Match the build configuration to how the app will be
  started. Anything the user launches themselves from the home screen must be
  `--release` (or `--profile`); Debug is only for `flutter run` or Xcode. And
  for any launch failure on device, run with `--console` before forming a
  hypothesis - the engine usually says what is wrong in plain English, and a
  bare signal number invites blaming the most recent diff.

### 2026-09-16 - Push died silently on a Supabase API key migration

- **Date**: 2026-09-16 (diagnosed 2026-09-17)
- **Failure Mode**: `send-clipboard-notification` returned 401 on every
  invocation for a day. Supabase migrated the project to its current API key
  scheme, so `SUPABASE_SERVICE_ROLE_KEY` became a 41-character `sb_secret_...`
  key while the `fcm_service_role_key` vault secret stayed the 219-character
  legacy JWT. The function compares them byte for byte to recognise its own
  trigger, so every call fell through to `auth.getUser()`, 403'd, and returned
  401 before reading the body. The same key change broke the devices query one
  layer deeper: it ran through a client built from the anon key with the
  caller's Authorization header forwarded, which worked only while that header
  was a JWT PostgREST could decode. Opaque keys have nothing to decode, so the
  query ran as anon against an RLS-protected table and 500'd.
- **Detection Signal**: Nothing surfaced it. The trigger fired, the client saw
  a successful send, the clip synced, and only the notification never arrived.
  Diagnosing it from the client was impossible - the app was healthy at every
  step because it was never the problem. What found it was a temporary
  diagnostic returning key lengths in the 401 body, read back out of
  `net._http_response`: pg_net records every response, and the dashboard logs
  do not carry console output.
- **Prevention Rule**: When a managed platform rotates or migrates key formats,
  audit every place a key is *compared* or *decoded*, not just the places it is
  read - a byte-for-byte comparison and a JWT decode both fail silently on an
  opaque key. Any path that reaches an RLS table on behalf of a trigger uses
  the admin client, never a forwarded Authorization header. And
  `verify_jwt = false` stays pinned in `supabase/config.toml`: `deploy.yml`
  deploys with no flags on every push to main, so without that file the next
  merge silently turns the platform JWT gate back on and breaks push again.
  For anything whose only symptom is silence, instrument the response body.

### 2026-09-17 - A background-wake feature that works "sometimes" is worse than none

- **Date**: 2026-09-17
- **Failure Mode**: The notification long-press Copy action needed the clip
  staged on the device by a background isolate woken by a `content-available`
  push. On a real iPhone the isolate woke and wrote `pending_push.json` but
  never staged the clip, and the fallback needs a network round trip a
  background action does not reliably get time for.
- **Detection Signal**: Worked on the simulator and failed on hardware, the
  usual shape for background-execution assumptions.
- **Prevention Rule**: Do not ship a control whose success depends on iOS
  granting background execution. iOS throttles background wake-ups on battery,
  Low Power Mode and usage, and refuses them outright for an app the user
  swiped away. A button that copies instantly sometimes and silently does
  nothing the rest of the time is worse than a tap that always behaves the same
  way - so the action was dropped rather than chased. Android keeps the fast
  path; its background execution is genuinely more permissive. When evaluating
  a similar feature, decide by the worst case the OS permits, not the best.

### 2026-09-25 - Read the second CMake error as the whole story and nearly patched the wrong thing

- **Date**: 2026-09-25
- **Failure Mode**: A Windows build failed at CMake configure with "Could NOT
  find JNI (missing: JVM)". Setting `JAVA_HOME` moved it on to a wall of MSVC
  syntax errors inside `jni/third_party/jni.h`, which declares `JNIEXPORT`
  with GCC attribute syntax. The obvious reading - that jni 0.14.2 simply does
  not compile on MSVC and needed a dependency override or an upstream patch -
  was wrong. `JAVA_INCLUDE_PATH` in `build/windows/x64/CMakeCache.txt` was
  still pointing at that bundled header from a configure done under a
  different jni version, which is the only reason the AOSP header was on the
  include path at all. `flutter clean` plus `JAVA_HOME` built it.
- **Detection Signal**: The cached value named a path that nothing in the
  currently resolved package's `CMakeLists.txt` could have set. Reading the
  installed 0.14.2 and the newer 1.0.3 side by side is what showed which
  version's logic had written it.
- **Prevention Rule**: A compile error inside a dependency's own headers, on a
  build that used to work, is a stale-build-directory suspect before it is an
  upstream-bug suspect. Check `CMakeCache.txt` for cached paths that the
  current source could not have produced, and clear the build directory, before
  reaching for a dependency override or an upstream patch - those are expensive
  and hard to back out. The second error a build reports is not necessarily the
  root cause of the first.

### 2026-09-25 - Heredocs in this shell eat backslash escapes

- **Date**: 2026-09-25
- **Failure Mode**: C++ written through a quoted `<<'EOF'` heredoc arrived with
  one level of backslash stripped, so `L'\'` became `L'\'` and the file did
  not compile ("newline in string literal"). A later Python heredoc lost the
  same way and its `assert` caught it before writing anything.
- **Detection Signal**: A compiler error on a line that looked right in the
  source that was sent. `cat -A` on the written file showed the difference.
- **Prevention Rule**: Do not write files containing backslashes - Windows
  paths, C/C++ escapes, regexes - through a heredoc here, even a quoted one.
  Use the Write or Edit tool for those. When a heredoc must be used, assert on
  the content afterwards rather than trusting it landed verbatim.

### 2026-09-25 - A startup crash that did not crash

- **Date**: 2026-09-25
- **Failure Mode**: Sentry reported a fatal `StateError` from
  `registerCurrentDevice` at launch. "Fatal" was misleading in both
  directions: the process was still alive, and it was worse off for it. The
  error escaped an unguarded `await` partway through `_appMain`, so everything
  after it - the tray icon, the global hotkey, the window - was never created.
  The mechanism tag said `PlatformDispatcher.onError`, which reports and lets
  the isolate continue, so what shipped was a resident process with no way to
  reach it and no visible sign anything was wrong.
- **Detection Signal**: The Sentry event, and then the fact that the process
  was still running when checked. Reproduced from the crash's own line
  numbers: `main.dart:400` matched the working tree but not `HEAD`, which is
  what identified the run as a local smoke test rather than a user's.
- **Prevention Rule**: In a startup sequence, an `await` before the app is
  reachable is load-bearing. Anything optional - signing in, registering a
  device, restoring caches - belongs behind a guard that reports and
  continues, and anything that is genuinely required should fail loudly rather
  than silently abandon the remaining setup. Also: `level: fatal` in Sentry
  means the error reached an unhandled-error handler, not that the process
  died. Check whether it did.

### 2026-09-25 - A checked return that was never checked

- **Date**: 2026-09-25
- **Failure Mode**: `AuthService.initialize()` called
  `signInAnonymously()` inside `try { } on AuthException`, and treated
  "did not throw" as "signed in". A response carrying no session is neither an
  exception nor a sign-in, so `initialize()` returned normally with
  `currentUser` still null, and the failure surfaced two call frames later as
  a `StateError` about device registration - naming the wrong subsystem
  entirely.
- **Detection Signal**: The reported error was a `StateError`, not an
  `AuthException`, which ruled out every path that throws and left only a
  silent one. Persisted preferences being `{}` confirmed no session had ever
  been written.
- **Prevention Rule**: When an SDK call returns a result *and* can throw,
  catching the throw covers half of it. Check the returned value for the thing
  the call was made to obtain, and fail at that point - an error raised where
  it happened names the right subsystem, which an error raised downstream
  never does.

### 2026-09-25 - Told the user to copy a command that reads the clipboard

- **Date**: 2026-09-25
- **Failure Mode**: The documented way to store the Sentry token read it from
  the clipboard, deliberately, because a typed console prompt truncates a long
  token silently. But the instruction was a multi-line snippet to copy and
  paste - and copying the snippet replaces the token on the clipboard with the
  snippet. What got DPAPI-encrypted and saved as the token was the setup
  command itself, 244 characters of PowerShell.
- **Detection Signal**: A check of the stored value before trusting it: it
  decrypted cleanly and was a plausible length, but contained newlines,
  quotes and `$`, which no token does. Nothing else would have caught it until
  a release build failed at upload.
- **Prevention Rule**: An instruction that reads the clipboard cannot itself
  be something the user copies. Put it in a script they run by name, and have
  the script validate what it found - reject whitespace, reject an implausible
  length, read the value back after writing it. For any secret the user pastes
  once and relies on later, the moment of storing it is the only cheap place
  to catch a mistake; everywhere downstream it is silent.

### 2026-09-25 - Went around the release script and lost a crash report

- **Date**: 2026-09-25
- **Failure Mode**: `installer/windows/build-store.ps1` exists so that a
  Windows build cannot be packaged without its PDBs going to Sentry first. To
  rebuild after an icon change I ran `flutter build windows --release` and
  `dart run msix:create` by hand instead, because they were quicker. That
  produced a new binary with new debug ids, shipped it, and uploaded nothing.
  The first native crash from it - an access violation near `SetWaitableTimer`
  - arrived with every frame unsymbolicated, which is precisely the outcome
  the script was written to prevent. Re-running the upload afterwards reported
  "Uploaded 1 missing debug information file", confirming the shipped build's
  symbols had never been sent.
- **Detection Signal**: A native crash whose stack was all `?`. The debug id
  told the story: the uploaded one ended `-3`, the installed binary's `-5`.
- **Prevention Rule**: When a project has a release script, use it for
  anything that produces a binary someone will run - not just for releases.
  The steps it bundles are bundled because doing them separately is easy to
  forget, and the cost is not paid at build time but weeks later when a crash
  report turns out to be unreadable. If a quicker path is genuinely needed,
  add a flag to the script rather than reproducing half of it by hand.
