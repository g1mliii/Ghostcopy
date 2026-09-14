-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:28:49 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix the INSERT policy to also check service_role
DROP POLICY IF EXISTS "service_role_only_insert" ON app_config;

CREATE POLICY "service_role_only_insert" ON app_config
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- Verify final state
SELECT policyname, cmd, qual FROM pg_policies 
WHERE tablename = 'app_config'
ORDER BY policyname;
