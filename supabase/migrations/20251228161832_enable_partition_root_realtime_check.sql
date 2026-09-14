-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 16:18:32 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Enable publish_via_partition_root if not already enabled
ALTER PUBLICATION supabase_realtime
SET (publish_via_partition_root = true);
