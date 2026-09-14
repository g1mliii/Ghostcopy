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

