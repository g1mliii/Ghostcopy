-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 16:07:39 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Enable Realtime for Partitioned Tables via Parent Table
--
-- Problem: clipboard table is partitioned (clipboard_p0 through clipboard_p15)
--          Realtime events are emitted for partition tables, not parent table
--          Subscribing to 'clipboard' doesn't catch partition inserts
--
-- Solution: Enable publish_via_partition_root so partition events appear
--           as if they came from the parent 'clipboard' table
--
-- This allows the client to subscribe ONLY to 'clipboard' instead of all 16 partitions

-- Enable publish_via_partition_root for supabase_realtime publication
ALTER PUBLICATION supabase_realtime
SET (publish_via_partition_root = true);

-- Verify the setting was applied
DO $$
DECLARE
  pub_via_root boolean;
BEGIN
  SELECT pubviaroot INTO pub_via_root
  FROM pg_publication
  WHERE pubname = 'supabase_realtime';

  IF NOT pub_via_root THEN
    RAISE EXCEPTION 'Failed to enable publish_via_partition_root';
  END IF;

  RAISE NOTICE 'Successfully enabled publish_via_partition_root for supabase_realtime';
END $$;
