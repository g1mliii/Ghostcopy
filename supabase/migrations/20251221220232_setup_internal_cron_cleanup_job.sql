-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 22:02:32 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Schedule deep cleanup to run daily at 2 AM UTC using internal pg_cron
-- This is much simpler than GitHub Actions - no external dependencies

-- Schedule the cleanup function to run every day at 2 AM UTC
-- Cron format: minute hour day month day-of-week
-- '0 2 * * *' = 2 AM UTC every day
SELECT cron.schedule(
  'cleanup-old-clips-daily',
  '0 2 * * *',
  'SELECT cleanup_old_clipboard_items_deep();'
);

-- Verify the job is scheduled
SELECT jobid, jobname, schedule, command, nodename, nodeport, database, username, active
FROM cron.job
WHERE jobname = 'cleanup-old-clips-daily';
