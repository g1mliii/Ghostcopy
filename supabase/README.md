# Supabase

## The repo is the source of truth

As of **2026-09-14** the local and remote migration histories are reconciled.
`supabase/migrations/` describes production exactly:

```
MATCHED both sides : 93
remote-only (drift): 0
local-only  (drift): 0
```

Schema changes now go in as migration files and reach production through
`supabase db push`, which CI runs for you. **Do not apply DDL through the
dashboard SQL editor** — that is what caused the drift described below, and it
will cause it again.

Check the state at any time (read-only, safe):

```bash
supabase migration list --linked
```

Any row with a `Remote` entry and no `Local` entry means someone applied DDL
outside the repo. `.github/workflows/deploy.yml` fails on exactly that before
it pushes anything.

### Making a schema change

```bash
supabase migration new describe_the_change   # creates a timestamped file
# edit supabase/migrations/<version>_describe_the_change.sql
supabase db push --dry-run --linked          # confirm what would run
```

Commit it. On merge to `main`, the `migrations` job in `deploy.yml` checks for
drift, dry-runs, then applies it. That job runs in the `production` GitHub
Environment — add required reviewers there so schema changes need approval, as
a bad migration is the one thing here that a re-run cannot undo.

## `schema.sql`

A dump of the live production schema, for reading. Regenerate with:

```bash
supabase db dump --linked -f supabase/schema.sql   # requires Docker running
```

Last regenerated 2026-09-14, immediately after reconciliation. It is a
convenience, not the source of truth — `migrations/` is.

## How the drift happened, and how it was fixed

The schema was originally built through the dashboard's SQL editor, which
recorded its own timestamped entries in the remote migration history without
writing files here. By 2026-09-11 the two sides had **zero** overlap:

| | Count |
|---|---|
| Applied in prod, no local file | 89 |
| Local file, not in prod history | 4 |
| Matched on both sides | **0** |

`supabase db push` was unusable: it refuses when the remote history contains
versions with no local file, and the four local files described DDL production
already had, so pushing them would have double-applied it.

The fix avoided rewriting production history:

1. **Recovered the 89.** `supabase_migrations.schema_migrations` stores the
   real SQL of every applied migration in its `statements` column. Each was
   written out as `<version>_<name>.sql` with its original version, name and
   statement text. Those files carry a header saying they are already applied —
   they are a record, not something to re-run.
2. **Marked the 4 as applied.** `supabase migration repair --status applied`
   for `20260911000000`, `20260911010000`, `20260913000000`, `20260914000000`.
   This inserts history rows and runs no DDL. It was verified first that every
   object those files create was already present in production (`pin_hash`,
   `pin_attempts`, `register_link_token_pin_failure`, `clipboard_user_id_fkey`)
   and that the one they remove was gone (`storage.delete_object`).
3. **Confirmed.** `db push --dry-run` reported `Remote database is up to date.`

An earlier plan had been to mark the 89 real migrations `reverted`, which would
have made the recorded history describe something that never happened.
Recovering them instead keeps the history true.

`migrations_archive/` holds 33 hand-written files that were maintained in
parallel and never applied through the CLI. They are kept as a record of intent
only — they never described what production ran. Do not apply them.

## Secrets

Two separate stores, and they are not interchangeable:

| Store | Read by | Holds |
|---|---|---|
| **Vault** (`vault.decrypted_secrets`) | Postgres triggers via `pg_net` | `supabase_api_url`, `fcm_service_role_key` |
| **Edge Function secrets** | `Deno.env.get()` | `FIREBASE_SERVICE_ACCOUNT`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET_NAME`, `R2_PUBLIC_URL` |

Edge functions run in Deno and **cannot read Vault** — they only see
environment variables. `SUPABASE_URL`, `SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY` are injected automatically; do not set them.

Note `cleanup_storage_on_clipboard_delete()` silently `RAISE WARNING`s and
returns if the Vault secrets are missing — deleted R2 objects would then linger
in a public bucket with no visible error.
