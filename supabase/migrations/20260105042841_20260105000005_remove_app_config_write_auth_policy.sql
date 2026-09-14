-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:28:41 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Remove the old auth write policy - only service_role should write to app_config
DROP POLICY IF EXISTS "app_config_write_auth" ON app_config;

-- Verify only service_role policies remain
SELECT policyname FROM pg_policies WHERE tablename = 'app_config' ORDER BY policyname;
