-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 16:18:25 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Verify publish_via_partition_root is enabled
DO $$
DECLARE
  pub_via_root boolean;
BEGIN
  SELECT pubviaroot INTO pub_via_root
  FROM pg_publication
  WHERE pubname = 'supabase_realtime';

  IF pub_via_root THEN
    RAISE NOTICE 'publish_via_partition_root is ENABLED ✓';
  ELSE
    RAISE NOTICE 'publish_via_partition_root is DISABLED ✗';
  END IF;
END $$;
