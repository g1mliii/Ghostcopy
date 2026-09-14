-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-27 15:57:00 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix auth_rls_initplan warnings by wrapping auth.uid() with SELECT
-- This caches the auth.uid() value instead of re-evaluating for each row

-- Fix clipboard partitions (p0-p15)
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p0;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p0 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p1;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p1 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p2;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p2 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p3;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p3 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p4;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p4 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p5;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p5 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p6;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p6 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p7;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p7 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p8;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p8 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p9;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p9 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p10;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p10 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p11;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p11 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p12;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p12 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p13;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p13 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p14;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p14 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard_p15;
CREATE POLICY users_view_own_clipboard_only ON clipboard_p15 FOR SELECT
  USING (user_id = (SELECT auth.uid()));

-- Fix app_config table policies
DROP POLICY IF EXISTS app_config_write_auth ON app_config;
CREATE POLICY app_config_write_auth ON app_config FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'authenticated');

DROP POLICY IF EXISTS app_config_update_auth ON app_config;
CREATE POLICY app_config_update_auth ON app_config FOR UPDATE
  WITH CHECK ((SELECT auth.role()) = 'authenticated');

DROP POLICY IF EXISTS app_config_delete_auth ON app_config;
CREATE POLICY app_config_delete_auth ON app_config FOR DELETE
  USING ((SELECT auth.role()) = 'authenticated');
