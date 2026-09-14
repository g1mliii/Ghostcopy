-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:27:57 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop existing policies
DROP POLICY IF EXISTS "Service role can read config" ON app_config;
DROP POLICY IF EXISTS "Service role can write config" ON app_config;
DROP POLICY IF EXISTS "Service role can update config" ON app_config;

-- Disable RLS first to set up policies
ALTER TABLE app_config DISABLE ROW LEVEL SECURITY;

-- Re-enable RLS with STRICT mode (more secure)
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

-- IMPORTANT: Only service_role can read secrets
-- Authenticated users CANNOT read this table
CREATE POLICY "service_role_only_read" ON app_config
  FOR SELECT
  USING (auth.role() = 'service_role');

CREATE POLICY "service_role_only_insert" ON app_config
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "service_role_only_update" ON app_config
  FOR UPDATE
  USING (auth.role() = 'service_role');

CREATE POLICY "service_role_only_delete" ON app_config
  FOR DELETE
  USING (auth.role() = 'service_role');

-- Revoke PostgREST access from regular users
REVOKE SELECT, INSERT, UPDATE, DELETE ON app_config FROM anon, authenticated;

COMMENT ON TABLE app_config IS 'SECRETS TABLE - Service role only. Contains sensitive configuration for database triggers. Never expose via API.';
