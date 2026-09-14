-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 16:23:12 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add all clipboard partition tables to realtime publication
-- This is a workaround in case publish_via_partition_root doesn't work with Supabase Realtime

DO $$
DECLARE
  partition_name text;
BEGIN
  FOR partition_name IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename LIKE 'clipboard_p%'
      AND tablename NOT LIKE '%_idx'
      AND tablename NOT LIKE '%_pkey'
  LOOP
    BEGIN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', partition_name);
      RAISE NOTICE 'Added partition % to realtime publication', partition_name;
    EXCEPTION
      WHEN duplicate_object THEN
        RAISE NOTICE 'Partition % already in realtime publication', partition_name;
    END;
  END LOOP;
END $$;
