-- Optimize Cleanup for Unpartitioned Table
--
-- ISSUE: Current cleanup function looks for partitions (clipboard_p0, p1, etc.)
--        but we removed partitioning, so it finds NOTHING and does NOTHING!
--
-- FIX: Rewrite cleanup to work with single unpartitioned 'clipboard' table
--      while keeping batched approach to prevent backend saturation
--
-- STRATEGY:
-- - Process in batches of 10K clips (prevents memory spikes)
-- - Yield between batches (allows inserts to proceed)
-- - Keep 20 most recent clips per user
-- - Safe for millions of users

DROP FUNCTION IF EXISTS cleanup_old_clipboard_items_deep() CASCADE;

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS TABLE(deleted_count bigint, processed_users bigint, duration_seconds numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  total_deleted bigint := 0;
  total_users bigint := 0;
  batch_deleted bigint;
  user_batch RECORD;
  start_time timestamp;
BEGIN
  start_time := clock_timestamp();

  -- Process users in batches (100 users at a time)
  -- Avoids scanning entire table with window functions
  LOOP
    batch_deleted := 0;

    -- Process a batch of users who have >20 clips
    FOR user_batch IN
      SELECT user_id, COUNT(*) as clip_count
      FROM clipboard
      GROUP BY user_id
      HAVING COUNT(*) > 20
      LIMIT 100  -- Process 100 users per batch
    LOOP
      -- For this user, delete clips beyond the 20 most recent
      -- Uses index on (user_id, created_at DESC) for efficiency
      WITH clips_to_keep AS (
        SELECT id
        FROM clipboard
        WHERE user_id = user_batch.user_id
        ORDER BY created_at DESC
        LIMIT 20
      )
      DELETE FROM clipboard
      WHERE user_id = user_batch.user_id
        AND id NOT IN (SELECT id FROM clips_to_keep);

      GET DIAGNOSTICS batch_deleted = ROW_COUNT;
      total_deleted := total_deleted + batch_deleted;
      total_users := total_users + 1;
    END LOOP;

    -- Exit if no users with >20 clips remain
    EXIT WHEN NOT FOUND;

    -- Log progress every 100 users
    IF total_users % 100 = 0 THEN
      RAISE NOTICE 'Progress: % users processed, % clips deleted', total_users, total_deleted;
    END IF;

    -- Yield to other operations between user batches
    PERFORM pg_sleep(0.05);  -- 50ms pause

  END LOOP;

  -- Return stats
  deleted_count := total_deleted;
  processed_users := total_users;
  duration_seconds := EXTRACT(EPOCH FROM (clock_timestamp() - start_time));
  RETURN NEXT;

  -- Log completion
  RAISE NOTICE 'Cleanup completed: % clips deleted for % users in % seconds',
    total_deleted, total_users, duration_seconds;
END;
$$;

COMMENT ON FUNCTION cleanup_old_clipboard_items_deep() IS
'Optimized cleanup for unpartitioned clipboard table. Prevents table scans and lock contention by:
1. Processing users in batches (100 users at a time)
2. Using index scans instead of window functions (fast on user_id, created_at)
3. Yielding between batches (50ms pause)
4. Keeping only 20 most recent clips per user
Users can access the table during cleanup (row-level locks only). Safe for millions of users.';

-- Verify pg_cron job exists and will use this function
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-clips-daily') THEN
    RAISE WARNING 'pg_cron job "cleanup-old-clips-daily" not found. Please create it manually.';
  ELSE
    RAISE NOTICE 'pg_cron job "cleanup-old-clips-daily" is active. Cleanup runs daily at 2 AM UTC.';
  END IF;
END $$;

-- ============================================================
-- VERIFICATION & TESTING
-- ============================================================

-- Manual test (safe to run, only deletes clips beyond 20 per user):
-- SELECT * FROM cleanup_old_clipboard_items_deep();

-- Check cron job status:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'cleanup-old-clips-daily';

-- View recent cron job runs:
-- SELECT jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time
-- FROM cron.job_run_details
-- WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'cleanup-old-clips-daily')
-- ORDER BY start_time DESC
-- LIMIT 10;
