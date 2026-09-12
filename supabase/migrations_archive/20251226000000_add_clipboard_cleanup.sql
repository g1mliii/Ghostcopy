-- Clipboard Cleanup System
--
-- Strategy: Display 10 clips, store up to 20 per user, clean daily via pg_cron
--
-- Benefits:
-- - Zero overhead on inserts (no triggers)
-- - No API calls from app (server-side only)
-- - Predictable storage: users × 20 clips max
-- - Daily cleanup at 2 AM UTC (off-peak)

-- ============================================================
-- CLEANUP FUNCTION: Keep 20 most recent clips per user
-- ============================================================

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TABLE(deleted_count bigint, processed_users bigint)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  total_deleted bigint := 0;
  user_count bigint := 0;
  user_rec RECORD;
BEGIN
  -- Iterate through users who have more than 20 clips
  FOR user_rec IN
    SELECT user_id, COUNT(*) as clip_count
    FROM clipboard
    GROUP BY user_id
    HAVING COUNT(*) > 20
  LOOP
    -- Delete old clips for this user (keep 20 most recent)
    WITH old_clips AS (
      SELECT id
      FROM clipboard
      WHERE user_id = user_rec.user_id
      ORDER BY created_at DESC
      OFFSET 20
    )
    DELETE FROM clipboard
    WHERE id IN (SELECT id FROM old_clips)
      AND user_id = user_rec.user_id;

    -- Track stats
    GET DIAGNOSTICS total_deleted = total_deleted + ROW_COUNT;
    user_count := user_count + 1;
  END LOOP;

  -- Return stats
  deleted_count := total_deleted;
  processed_users := user_count;
  RETURN NEXT;

  -- Log the cleanup
  RAISE NOTICE 'Cleanup completed: % clips deleted for % users', total_deleted, user_count;
END;
$$;

COMMENT ON FUNCTION cleanup_old_clipboard_items() IS
'Daily cleanup function that keeps only the 20 most recent clipboard items per user. Runs via pg_cron at 2 AM UTC.';

-- ============================================================
-- PG_CRON SETUP: Schedule daily cleanup at 2 AM UTC
-- ============================================================

-- Enable pg_cron extension (if not already enabled)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Unschedule any existing cleanup jobs (idempotent)
SELECT cron.unschedule('cleanup-old-clipboard-items')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-clipboard-items'
);

-- Schedule daily cleanup at 2 AM UTC
SELECT cron.schedule(
  'cleanup-old-clipboard-items',           -- Job name
  '0 2 * * *',                             -- Every day at 2 AM UTC
  $$SELECT * FROM cleanup_old_clipboard_items()$$  -- SQL to execute
);

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL - used for daily clipboard cleanup';

-- ============================================================
-- VERIFICATION QUERY (for testing)
-- ============================================================

-- To manually test the cleanup function:
-- SELECT * FROM cleanup_old_clipboard_items();

-- To check the cron schedule:
-- SELECT * FROM cron.job WHERE jobname = 'cleanup-old-clipboard-items';

-- To see cron job history:
-- SELECT * FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'cleanup-old-clipboard-items') ORDER BY start_time DESC LIMIT 10;
