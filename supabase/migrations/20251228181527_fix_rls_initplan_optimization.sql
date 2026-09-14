-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 18:15:27 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix RLS InitPlan Optimization
--
-- ISSUE: Using auth.uid() and auth.role() directly causes re-evaluation for EACH ROW
--        This is SLOW at scale (Supabase performance advisor warning)
--
-- CORRECT FIX: Wrap auth functions with (SELECT ...) to create InitPlan
--              PostgreSQL evaluates InitPlan ONCE and caches the result
--              Much faster for queries returning many rows
--
-- Source: https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select

-- ============================================================
-- CLIPBOARD TABLE (4 policies to fix)
-- ============================================================

DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard;
DROP POLICY IF EXISTS users_insert_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_update_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_delete_own_clipboard ON clipboard;

CREATE POLICY users_view_own_clipboard_only ON clipboard
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE POLICY users_insert_own_clipboard ON clipboard
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY users_update_own_clipboard ON clipboard
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY users_delete_own_clipboard ON clipboard
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ============================================================
-- DEVICES TABLE (4 policies to fix)
-- ============================================================

DROP POLICY IF EXISTS users_view_own_devices ON devices;
DROP POLICY IF EXISTS users_insert_own_devices ON devices;
DROP POLICY IF EXISTS users_update_own_devices ON devices;
DROP POLICY IF EXISTS users_delete_own_devices ON devices;

CREATE POLICY users_view_own_devices ON devices
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE POLICY users_insert_own_devices ON devices
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY users_update_own_devices ON devices
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY users_delete_own_devices ON devices
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

-- ============================================================
-- APP_CONFIG TABLE (3 policies to fix)
-- ============================================================

DROP POLICY IF EXISTS app_config_write_auth ON app_config;
DROP POLICY IF EXISTS app_config_update_auth ON app_config;
DROP POLICY IF EXISTS app_config_delete_auth ON app_config;

CREATE POLICY app_config_write_auth ON app_config
  FOR INSERT
  TO authenticated
  WITH CHECK ((SELECT auth.role()) = 'authenticated');

CREATE POLICY app_config_update_auth ON app_config
  FOR UPDATE
  TO authenticated
  WITH CHECK ((SELECT auth.role()) = 'authenticated');

CREATE POLICY app_config_delete_auth ON app_config
  FOR DELETE
  TO authenticated
  USING ((SELECT auth.role()) = 'authenticated');
