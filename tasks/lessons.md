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
