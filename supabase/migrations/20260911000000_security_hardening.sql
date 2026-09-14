-- Security hardening pass, 2026-09-11
--
-- Derived from a full audit of the live schema (supabase/schema.sql).
-- Safe to run on the current near-empty production database.
--
-- Run this in the Supabase dashboard SQL editor, or via psql. Do NOT run
-- `supabase db push` - local and remote migration histories are fully
-- diverged (see supabase/README.md) and push would try to replay 33 archived
-- files that were never applied.
--
-- Every statement is idempotent or guarded, so re-running is safe.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. clipboard.user_id lacked ON DELETE CASCADE
-- ---------------------------------------------------------------------------
-- devices, mobile_link_tokens and user_rate_limit all declare CASCADE;
-- clipboard alone defaulted to NO ACTION. Deleting an account therefore fails
-- with 23503 for any user who has ever synced a clip - i.e. every real user -
-- and the blocking table is the one holding plaintext passwords and API keys.
-- The AFTER DELETE trigger fires per row on cascade, so R2 objects still get
-- cleaned up.
ALTER TABLE public.clipboard
  DROP CONSTRAINT IF EXISTS clipboard_new_user_id_fkey1;

ALTER TABLE public.clipboard
  DROP CONSTRAINT IF EXISTS clipboard_user_id_fkey;

ALTER TABLE public.clipboard
  ADD CONSTRAINT clipboard_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


-- ---------------------------------------------------------------------------
-- 2. SECURITY DEFINER functions did not pin pg_temp in search_path
-- ---------------------------------------------------------------------------
-- When pg_temp is not named explicitly it is searched FIRST for relation
-- names. A caller able to run `CREATE TEMP TABLE user_rate_limit (...)` would
-- have these definer-rights functions read and write their own empty shadow
-- table, permanently disabling the clipboard rate limit and the 10-device cap.
--
-- Not reachable through PostgREST today (anon/authenticated are NOLOGIN and
-- have no route to CREATE TEMP TABLE), but it costs nothing to close and
-- becomes live the moment any direct-SQL path appears.
-- cleanup_stale_rate_limits already does this correctly.
ALTER FUNCTION public.check_clipboard_rate_limit()
  SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.check_devices_rate_limit()
  SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.cleanup_old_clipboard_items(uuid, integer)
  SET search_path TO 'public', 'pg_temp';

ALTER FUNCTION public.cleanup_old_clipboard_items_deep()
  SET search_path TO 'public', 'pg_temp';


-- ---------------------------------------------------------------------------
-- 3. GRANT ALL to anon/authenticated included privileges RLS does not mediate
-- ---------------------------------------------------------------------------
-- ALL expands to SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES,
-- TRIGGER, MAINTAIN. Row-level security governs none of the last four:
--   * TRUNCATE on clipboard wipes every user's rows in one statement.
--   * TRIGGER lets a grantee attach a trigger that fires on OTHER users'
--     inserts - a cross-user exfiltration primitive on the table holding the
--     secrets.
--   * GRANT ALL on the sequence permits setval(), so resetting clipboard_id_seq
--     makes every subsequent insert collide on the primary key for all users.
-- The app needs four verbs. These are Supabase's stock dashboard grants.
REVOKE ALL ON TABLE public.clipboard FROM anon, authenticated;
REVOKE ALL ON TABLE public.devices   FROM anon, authenticated;

-- anon holds no RLS policy on either table, so it is denied every row anyway;
-- granting only to authenticated makes that explicit rather than incidental.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.clipboard TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.devices   TO authenticated;

REVOKE TRUNCATE, TRIGGER, REFERENCES, MAINTAIN
  ON TABLE public.mobile_link_tokens, public.app_config
  FROM anon, authenticated;

REVOKE ALL ON SEQUENCE public.clipboard_id_seq FROM anon, authenticated;
GRANT USAGE ON SEQUENCE public.clipboard_id_seq TO authenticated;

-- Without this, the NEXT table added to public starts life granted ALL to anon.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. FCM tokens were claimable by more than one account
-- ---------------------------------------------------------------------------
-- unique_user_token is UNIQUE (user_id, fcm_token) - scoped PER USER - so any
-- number of accounts could register the same registration token. Combined with
-- the (now fixed) unvalidated `record` branch in send-clipboard-notification,
-- that allowed pushing attacker-chosen content into another user's clipboard.
-- A registration token identifies one physical device and must be global.
DELETE FROM public.devices a
  USING public.devices b
  WHERE a.fcm_token IS NOT NULL
    AND a.fcm_token = b.fcm_token
    AND a.ctid > b.ctid;

CREATE UNIQUE INDEX IF NOT EXISTS devices_fcm_token_global_unique
  ON public.devices (fcm_token)
  WHERE fcm_token IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 5. Link tokens had no server-side expiry ceiling
-- ---------------------------------------------------------------------------
-- expires_at is supplied by the client and the INSERT policy checks only
-- user_id, so a modified client could mint a link token that never expires.
-- Entropy, single-use consumption and expiry enforcement are all already
-- correct; this only bounds the TTL.
ALTER TABLE public.mobile_link_tokens
  DROP CONSTRAINT IF EXISTS mobile_link_tokens_max_ttl;

ALTER TABLE public.mobile_link_tokens
  ADD CONSTRAINT mobile_link_tokens_max_ttl
  CHECK (expires_at <= created_at + INTERVAL '10 minutes') NOT VALID;


-- ---------------------------------------------------------------------------
-- 6. Remove redundant indexes
-- ---------------------------------------------------------------------------
-- Pure write overhead on hot paths.
--   idx_user_rate_limit_user_id duplicates user_rate_limit_pkey
--   idx_mobile_link_tokens_token duplicates mobile_link_tokens_token_key
--   idx_devices_user_id is a strict prefix of idx_devices_user_device_type
DROP INDEX IF EXISTS public.idx_user_rate_limit_user_id;
DROP INDEX IF EXISTS public.idx_mobile_link_tokens_token;
DROP INDEX IF EXISTS public.idx_devices_user_id;


-- ---------------------------------------------------------------------------
-- 7. Validate the NOT VALID constraints
-- ---------------------------------------------------------------------------
-- Both are enforced on new writes but pre-existing rows were never checked.
-- Cheap now while the table is near-empty; will error if a legacy row violates,
-- which is exactly what you want to know.
ALTER TABLE public.clipboard
  VALIDATE CONSTRAINT clipboard_storage_path_owned_by_user;

ALTER TABLE public.mobile_link_tokens
  VALIDATE CONSTRAINT mobile_link_tokens_token_sha256;

COMMIT;


-- ===========================================================================
-- RUN SEPARATELY - verification, not a change
-- ===========================================================================
-- The clipboard-insert and storage-delete triggers both pass the service-role
-- key to pg_net, which stores it as cleartext JSONB in
-- net.http_request_queue.headers. If anon or authenticated can read the `net`
-- schema, that key is harvestable by anyone holding the public anon key - and
-- it reads every user's clipboard. An empty database does not make a leaked
-- service-role key harmless.
--
--   SELECT has_schema_privilege('anon','net','USAGE') AS anon_usage,
--          has_schema_privilege('authenticated','net','USAGE') AS auth_usage;
--
--   SELECT grantee, table_name, privilege_type
--     FROM information_schema.role_table_grants
--    WHERE table_schema = 'net' AND grantee IN ('anon','authenticated');
--
-- If either returns true / any rows:
--   REVOKE ALL ON ALL TABLES IN SCHEMA net FROM anon, authenticated;
--   REVOKE USAGE ON SCHEMA net FROM anon, authenticated;
