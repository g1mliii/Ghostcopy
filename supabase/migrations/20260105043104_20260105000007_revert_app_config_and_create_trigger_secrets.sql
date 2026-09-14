-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:31:04 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- REVERT: Allow authenticated users to read app_config for hybrid_mode_enabled
DROP POLICY IF EXISTS "service_role_only_read" ON app_config;
DROP POLICY IF EXISTS "service_role_only_insert" ON app_config;
DROP POLICY IF EXISTS "service_role_only_update" ON app_config;
DROP POLICY IF EXISTS "service_role_only_delete" ON app_config;

-- New policies for app_config - allow authenticated/anon to read
CREATE POLICY "authenticated_read_app_config" ON app_config
  FOR SELECT
  USING (auth.role() IN ('authenticated', 'anon'));

CREATE POLICY "service_role_write_app_config" ON app_config
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "service_role_update_app_config" ON app_config
  FOR UPDATE
  USING (auth.role() = 'service_role');

-- Remove service_role_key and supabase_url from app_config (keep only hybrid_mode_enabled)
DELETE FROM app_config WHERE key IN ('service_role_key', 'supabase_url');

-- CREATE NEW TABLE: trigger_secrets (service_role only)
CREATE TABLE IF NOT EXISTS trigger_secrets (
  key text PRIMARY KEY,
  value text NOT NULL,
  enabled boolean DEFAULT true,
  updated_at timestamptz DEFAULT timezone('utc', now())
);

-- STRICT RLS: Only service_role can access trigger_secrets
ALTER TABLE trigger_secrets ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_only_read_secrets" ON trigger_secrets
  FOR SELECT
  USING (auth.role() = 'service_role');

CREATE POLICY "service_role_only_insert_secrets" ON trigger_secrets
  FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "service_role_only_update_secrets" ON trigger_secrets
  FOR UPDATE
  USING (auth.role() = 'service_role');

CREATE POLICY "service_role_only_delete_secrets" ON trigger_secrets
  FOR DELETE
  USING (auth.role() = 'service_role');

-- Revoke all access from authenticated/anon
REVOKE SELECT, INSERT, UPDATE, DELETE ON trigger_secrets FROM anon, authenticated;

-- Insert secrets into new table
INSERT INTO trigger_secrets (key, value, enabled) VALUES
  ('service_role_key', '', true),
  ('supabase_url', 'https://xhbggxftvnlkotvehwmj.supabase.co', true)
ON CONFLICT (key) DO UPDATE SET
  value = EXCLUDED.value,
  enabled = EXCLUDED.enabled;

COMMENT ON TABLE trigger_secrets IS 'SECURE - Service role only. Secrets for database triggers (FCM notifications). Never expose via API.';
COMMENT ON TABLE app_config IS 'App configuration readable by all authenticated users. For feature flags like hybrid_mode_enabled.';
