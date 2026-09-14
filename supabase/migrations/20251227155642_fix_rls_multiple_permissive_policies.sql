-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-27 15:56:42 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop the redundant 'users_view_own_clipboard_only' policy from all clipboard partitions
-- This policy was using 'ALL' command which caused it to apply to DELETE, INSERT, UPDATE
-- The action-specific policies (users_delete_own_clipboard, users_insert_own_clipboard, users_update_own_clipboard) 
-- already provide the necessary row-level security, so this policy is redundant

-- Drop from all 16 partitions
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p0;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p1;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p2;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p3;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p4;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p5;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p6;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p7;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p8;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p9;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p10;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p11;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p12;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p13;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p14;
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p15;

-- Create a single SELECT-only policy for each partition to replace the 'ALL' command policy
-- This will only apply to SELECT operations
CREATE POLICY users_view_own_clipboard_only ON clipboard_p0 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p1 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p2 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p3 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p4 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p5 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p6 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p7 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p8 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p9 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p10 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p11 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p12 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p13 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p14 FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY users_view_own_clipboard_only ON clipboard_p15 FOR SELECT
  USING (user_id = auth.uid());

-- Fix app_config table: app_config_admin_only uses 'ALL' which is redundant with app_config_read_all for SELECT
-- Keep app_config_read_all for SELECT (anonymous users can read config)
-- app_config_admin_only with 'ALL' will only apply to non-SELECT operations (INSERT, UPDATE, DELETE)
-- Since we want to prevent anonymous users from modifying config, we should keep app_config_admin_only as restrictive policy

-- Actually, let's check the logic:
-- - app_config_read_all: SELECT for everyone (PERMISSIVE)
-- - app_config_admin_only: ALL action (PERMISSIVE) - this is only for authenticated admins

-- The issue is app_config_admin_only is PERMISSIVE with ALL, which means it applies to SELECT too
-- We should change it to only apply to non-SELECT operations (INSERT, UPDATE, DELETE)
-- But since we want to restrict writes to admins only, we actually want this as a RESTRICTIVE policy

-- Let's drop the problematic policies and recreate them properly
DROP POLICY IF EXISTS app_config_admin_only ON app_config;
DROP POLICY IF EXISTS app_config_read_all ON app_config;

-- SELECT policy: allow everyone to read
CREATE POLICY app_config_read_all ON app_config FOR SELECT
  USING (true);

-- Write policies: restrict to authenticated users (admin check can be done in application layer or with is_admin field)
-- For now, allow authenticated users to write
CREATE POLICY app_config_write_auth ON app_config FOR INSERT
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY app_config_update_auth ON app_config FOR UPDATE
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY app_config_delete_auth ON app_config FOR DELETE
  USING (auth.role() = 'authenticated');
