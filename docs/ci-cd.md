# CI/CD

GitHub Actions. The gate is deliberately small and fast; everything expensive or
unproven is opt-in, so a red check always means a real regression.

| Workflow | File | Trigger | Blocking? |
|---|---|---|---|
| CI | `ci.yml` | push/PR to `main` | **Yes** |
| Web & backend | `web-backend.yml` | push/PR touching `website/`, `supabase/functions/` | Website yes, Deno advisory |
| Deploy | `deploy.yml` | push to `main`, or manual | n/a |
| Build check | `build-check.yml` | manual, or weekly | No |

Flutter is pinned to **3.44.8** (`FLUTTER_VERSION`) in every workflow. Bump it in
all files at once, deliberately — CI should never move because a new stable
shipped.

## `ci.yml` — the gate

Dart only, on Ubuntu, ~3 minutes:

- `dart format --output=none --set-exit-if-changed lib test`
- `flutter analyze --no-pub`
- `flutter test --coverage` (coverage uploaded as an artifact)

All three pass on `main` today: **98 tests pass, 1 skipped**, analyzer clean,
formatter clean.

No platform builds here — the app is not packaged or distributed yet, and store
distribution (Play Console / App Store Connect) is a separate pipeline that
Actions would not own anyway.

The golden test (`test/golden/mobile_visual_test.dart`) is `skip: true`. **Leave
it skipped in CI.** Goldens are pixel-compared and were generated on Windows;
they will not reproduce on a Linux runner's font stack.

`flutter test` gets no `--reporter` flag on purpose: it defaults to its `github`
reporter on Actions, which annotates failures inline on the diff.

## `build-check.yml` — opt-in native compiles

Windows, Android, macOS and iOS, run from the Actions tab (pick a platform) or
weekly on Mondays. Every job is `continue-on-error`.

This is worth keeping even before distribution, because `flutter analyze` only
reads Dart. It cannot see a Gradle/AGP mismatch, a plugin needing a newer
`compileSdk`, a CocoaPods failure, or a broken MSVC link — exactly the class of
break behind the `compileSdk = 37` note in `android/app/build.gradle.kts`.

**macOS and iOS have never been verified by hand.** Do not make them required
checks until they are proven on real hardware.

Android needs a Firebase stub to compile at all — see below.

## `web-backend.yml`

- **Website** — `npm install && npm run build`. Verified working locally.
- **Edge functions** — `deno check` + `deno lint`, both **advisory**. The three
  deployed functions currently have ~13 strict type errors between them, mostly
  implicit `any` on Supabase/Firebase callback parameters.
  `supabase functions deploy` does not type-check, so these are not deploy
  blockers and the functions work in production. Fix them, then delete the
  `continue-on-error` lines to turn this into a real gate.

## `deploy.yml` — the actual CD

Deploys only what changed on a push to `main`, or a chosen target manually:

- **Website** → Cloudflare Pages, mirroring the `deploy` script in
  `website/package.json`
- **Edge functions** → Supabase, skipping `_shared` and never touching
  `functions_archive/`
- **Migrations** → `supabase db push`, drift-checked and dry-run first (see
  below)

Both run in the `production` GitHub Environment, so you can add required
reviewers under *Settings → Environments* to make deploys gated.

## Required secrets

*Settings → Secrets and variables → Actions*.

| Secret | Needed by | Notes |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | `deploy.yml` | needs Pages:Edit |
| `CLOUDFLARE_ACCOUNT_ID` | `deploy.yml` | |
| `SUPABASE_ACCESS_TOKEN` | `deploy.yml` | personal access token |
| `SUPABASE_PROJECT_REF` | `deploy.yml` | the project ref |

None are needed for `ci.yml` — the Supabase URL and anon key are compiled into
`lib/main.dart` on purpose (the anon key is `role: anon`, protected by RLS, and
is meant to ship in clients).

### The Android Firebase stub

`android/app/google-services.json` is gitignored, but the
`com.google.gms.google-services` Gradle plugin refuses to run without it — so a
fresh clone **cannot build an APK at all**. `build-check.yml` copies
`.github/ci/google-services.placeholder.json` into place: structurally valid,
enough for Gradle, and the resulting APK could not receive push notifications.
That is fine because the job only proves the code compiles and uploads nothing.

When real APKs matter, add `GOOGLE_SERVICES_JSON` as a base64 secret and swap
the stub step for a decode step:

```bash
base64 -w0 android/app/google-services.json    # Linux
base64 -i android/app/google-services.json     # macOS
```

## Database migrations

Automated as of 2026-09-14, once the local and remote migration histories were
reconciled (93 matched, zero drift). Before that `db push` would have
double-applied existing DDL; the recovery is written up in
`supabase/README.md`.

The `migrations` job in `deploy.yml` does three things in order:

1. **Drift check** — fails if any migration applied to production has no file in
   `supabase/migrations/`. That means someone applied DDL through the dashboard,
   and pushing on top of it is exactly the situation that caused the original
   mess.
2. **Dry run** — prints what would be applied.
3. **Apply** — `supabase db push`.

**Add required reviewers to the `production` environment.** DDL is the one thing
in this repo a re-run cannot undo, so a schema change should need a human
approval. Everything else here is idempotent; this is not.

Apply schema changes as migration files from now on, never through the dashboard
SQL editor.

## Known gaps

- **No lockfiles.** `pubspec.lock` and `website/package-lock.json` are both
  gitignored, so every run resolves fresh and builds are not reproducible.
  Committing `pubspec.lock` (normal for an application, as opposed to a package)
  would fix the Flutter side and let the website move to `npm ci`.
- **Android release signs with the debug keystore**
  (`android/app/build.gradle.kts`). Fine for sideloading, not upload-ready for
  Play. Needs a real `signingConfig` plus keystore secrets before any store
  release.
- **macOS/iOS unverified** — see `build-check.yml`.
