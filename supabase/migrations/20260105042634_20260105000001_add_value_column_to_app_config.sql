-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:26:34 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add value column to app_config if it doesn't exist
ALTER TABLE app_config ADD COLUMN IF NOT EXISTS value text;

-- Insert or update service_role_key configuration
-- User needs to manually update this with their actual service role key from Supabase dashboard
INSERT INTO app_config (key, value, enabled) VALUES
  ('service_role_key', '', true)
ON CONFLICT (key) DO UPDATE SET 
  value = EXCLUDED.value,
  enabled = true;

INSERT INTO app_config (key, value, enabled) VALUES
  ('supabase_url', 'https://xhbggxftvnlkotvehwmj.supabase.co', true)
ON CONFLICT (key) DO UPDATE SET 
  value = EXCLUDED.value,
  enabled = true;
