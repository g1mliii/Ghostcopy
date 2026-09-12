# Supabase

## Production is the source of truth

`schema.sql` is a dump of the **live** production schema
(project `xhbggxftvnlkotvehwmj`, captured 2026-09-11). It is the authoritative
description of the database. Regenerate it with:

```bash
supabase db dump --linked -f supabase/schema.sql   # requires Docker running
```

It contains 5 tables (`clipboard`, `devices`, `app_config`,
`mobile_link_tokens`, `user_rate_limit`), 5 triggers, 11 functions, 14 RLS
policies and 16 indexes.

## Why `migrations/` is empty

The production schema was built through the Supabase dashboard's SQL editor,
which records its own timestamped entries in the remote migration history. The
hand-written files that used to live in `migrations/` were maintained in
parallel and **never applied through the CLI**. As of 2026-09-11:

| | Count |
|---|---|
| Local files, not in remote history | 33 |
| Applied in prod, not in repo | 89 |
| Matched on both sides | **0** |

Zero overlap. Those 33 files are preserved in `migrations_archive/` as a record
of intent, but they never described what prod actually ran, and applying them
now would double-apply DDL that already exists.

**Do not run `supabase db push`.**

## If you want CLI-managed migrations again

`supabase db pull` refuses while the histories disagree, and its suggested fix
is ~122 `supabase migration repair` calls that rewrite the **production**
migration history table — marking 89 real migrations "reverted" and local files
"applied". That makes the recorded history describe something that never
happened, so it was deliberately not done.

The honest path, when you want it:

1. Write `schema.sql` as a single baseline migration, e.g.
   `migrations/20260911000000_baseline.sql`.
2. `supabase migration repair --status applied 20260911000000` so the remote
   history records that baseline.
3. Take every schema change from then on as a new migration file applied with
   `supabase db push` — not through the dashboard.

Step 2 writes to production metadata, so do it deliberately.

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
