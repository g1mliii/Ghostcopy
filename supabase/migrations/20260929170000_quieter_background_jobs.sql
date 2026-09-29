-- Background work that ran far more often than it had anything to do, found
-- from the logs and pg_stat_statements on 2026-09-29. Three jobs ran every
-- five minutes around the clock (87 runs each in a 7-hour sample), each
-- adding a cron.job_run_details row that nothing ever removed - 20,183 rows
-- back to December 2025.

-- 1. cleanup_stale_rate_limits was scheduled twice: daily at 03:00
--    ('cleanup-stale-rate-limits-daily') and every five minutes as
--    'cleanup-expired-transient-data'. It only deletes rows older than a day
--    and expired QR link tokens - exchange-link-token refuses an expired token
--    itself (expires_at > now), so prompt deletion adds nothing. The daily run
--    stays; the five-minute copy goes.
--
--    The daily job was created in the dashboard and no migration schedules
--    it, so a database built from these migrations alone would lose its only
--    run here. It is (re)scheduled first, by name, so this holds anywhere.
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'cleanup-stale-rate-limits-daily';
SELECT cron.schedule('cleanup-stale-rate-limits-daily', '0 3 * * *',
  'SELECT public.cleanup_stale_rate_limits()');
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'cleanup-expired-transient-data';

-- 2. Clip retention: every five minutes to hourly. The function is bounded -
--    at most 1000 users and 5000 deletions a run, resuming from a cursor - so
--    hourly still drains 120,000 rows a day, far above current load.
--
--    Two signals to speed it back up. Either one means a faster schedule:
--      - deleted_count = 5000 regularly: each run ends with its deletion
--        budget spent (from 20260916210000_relax_cleanup_cron_cadence.sql).
--      - processed_users = 1000 regularly: each run visits its full 1000
--        users, so one pass over every account spans several runs. Hourly
--        covers 24,000 users a day; past that, some accounts wait more than
--        a day to be trimmed while deleted_count still looks low.
--    Both come back from:
--      SELECT deleted_count, processed_users
--      FROM public.cleanup_old_clipboard_items_deep();
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'cleanup-old-clips-bounded';
SELECT cron.schedule('cleanup-old-clips-bounded', '7 * * * *',
  'SELECT * FROM public.cleanup_old_clipboard_items_deep()');

-- 3. Storage deletion queue: every five minutes to every fifteen. It already
--    returns before calling the storage-presign edge function when nothing is
--    due, so this only spaces out an R2 delete no one is waiting on.
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'cleanup-storage-queue';
SELECT cron.schedule('cleanup-storage-queue', '*/15 * * * *',
  'SELECT public.dispatch_storage_cleanup()');

-- 4. cron.job_run_details is pg_cron's own log and is never trimmed. Keep a
--    week, which is what a failed job is investigated with.
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'purge-cron-history';
SELECT cron.schedule('purge-cron-history', '31 4 * * *',
  $$DELETE FROM cron.job_run_details WHERE end_time < now() - interval '7 days'$$);

-- 5. public.devices was in the supabase_realtime publication, but no client
--    subscribes to it - only clipboard is watched (clipboard_sync_service and
--    watchHistory). Every devices write, like the hourly push-token reassert
--    and last_active, was still decoded from the WAL by Realtime for no one.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public' AND tablename = 'devices'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.devices;
  END IF;
END $$;

-- 6. The security advisor flags claim_fcm_token as a SECURITY DEFINER function
--    callable by authenticated users. That is deliberate, and recorded here so
--    the flag is not "fixed" by breaking it.
COMMENT ON FUNCTION public.claim_fcm_token(uuid, text) IS
  'SECURITY DEFINER on purpose. A phone that signs into another account must '
  'clear its push token from the previous account''s device row, which the '
  'caller''s RLS cannot reach - otherwise both accounts'' clips notify that '
  'phone. It requires a session, writes only into a row the caller owns, and '
  'rejects anything too short to be an FCM token.';
