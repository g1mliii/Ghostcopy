-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:33:39 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop the old trigger_secrets table (plain text approach)
DROP TABLE IF EXISTS trigger_secrets CASCADE;

-- Create secrets in Supabase Vault (encrypted storage)
-- Syntax: vault.create_secret(secret_value, optional_name, optional_description)

-- Create the service_role_key secret (empty for now - user populates via Supabase UI)
SELECT vault.create_secret(
  '',
  'fcm_service_role_key',
  'Service role key for FCM notifications via database triggers'
);

-- Create the supabase URL secret
SELECT vault.create_secret(
  'https://xhbggxftvnlkotvehwmj.supabase.co',
  'supabase_api_url',
  'Supabase project URL for edge function invocations'
);
