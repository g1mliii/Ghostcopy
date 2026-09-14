-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:39:26 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix RLS performance warnings on app_config by using (select auth.role()) instead of auth.role()
-- This evaluates the function once instead of for each row

DROP POLICY IF EXISTS "authenticated_read_app_config" ON app_config;
DROP POLICY IF EXISTS "service_role_write_app_config" ON app_config;
DROP POLICY IF EXISTS "service_role_update_app_config" ON app_config;

-- Recreate with optimized subqueries (evaluated once, not per row)
CREATE POLICY "authenticated_read_app_config" ON app_config
  FOR SELECT
  USING ((select auth.role()) IN ('authenticated', 'anon'));

CREATE POLICY "service_role_write_app_config" ON app_config
  FOR INSERT
  WITH CHECK ((select auth.role()) = 'service_role');

CREATE POLICY "service_role_update_app_config" ON app_config
  FOR UPDATE
  USING ((select auth.role()) = 'service_role');
