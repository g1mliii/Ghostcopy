-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:40:28 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Enable pg_net extension for async HTTP calls from database triggers
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Verify it's enabled
SELECT extname FROM pg_extension WHERE extname = 'pg_net';
