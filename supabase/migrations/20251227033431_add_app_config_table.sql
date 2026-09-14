-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-27 03:34:31 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Create app_config table for feature flags
-- This enables dynamic control of hybrid realtime/polling mode
CREATE TABLE IF NOT EXISTS app_config (
  key text PRIMARY KEY,
  enabled boolean DEFAULT false,
  created_at timestamptz DEFAULT timezone('utc', now()),
  updated_at timestamptz DEFAULT timezone('utc', now())
);

-- Insert hybrid mode flag (disabled by default for safe rollout)
INSERT INTO app_config (key, enabled)
VALUES ('hybrid_mode_enabled', false)
ON CONFLICT (key) DO NOTHING;

-- Add RLS policies (admins only can modify, everyone can read)
ALTER TABLE app_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY app_config_read_all ON app_config
  FOR SELECT
  USING (true);  -- Everyone can read feature flags

CREATE POLICY app_config_admin_only ON app_config
  FOR ALL
  USING (false);  -- No one can modify (use Supabase dashboard)

-- Add comments for documentation
COMMENT ON TABLE app_config IS 'Application-wide feature flags and configuration';
COMMENT ON COLUMN app_config.key IS 'Unique configuration key (e.g., hybrid_mode_enabled)';
COMMENT ON COLUMN app_config.enabled IS 'Boolean flag for enabling/disabling features';
