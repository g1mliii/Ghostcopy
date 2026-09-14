-- Optimize Clipboard Cleanup: Remove Expensive Triggers
--
-- CURRENT PROBLEM:
-- - 17 triggers (1 parent + 16 partitions) run on EVERY insert
-- - Adds latency to critical path (sending clipboard)
-- - Resource intensive at scale
--
-- NEW STRATEGY:
-- - Remove ALL triggers (zero insert overhead)
-- - Single pg_cron job at 2 AM UTC
-- - Maintains 20 clips per user (not time-based)
-- - Off-peak processing, no user impact

-- ============================================================
-- STEP 1: Drop all cleanup triggers (17 total)
-- ============================================================

-- Drop triggers from all partitions
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p0 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p1 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p2 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p3 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p4 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p5 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p6 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p7 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p8 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p9 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p10 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p11 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p12 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p13 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p14 CASCADE;
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard_p15 CASCADE;

-- Drop old trigger-based cleanup function (no longer needed)
DROP FUNCTION IF EXISTS cleanup_old_clipboard_items() CASCADE;

-- ============================================================
-- STEP 2: Replace old deep cleanup with optimized version
-- ============================================================

-- Drop old deep cleanup function (deletes >30 days)
DROP FUNCTION IF EXISTS cleanup_old_clipboard_items_deep() CASCADE;

-- Create NEW optimized cleanup function (keeps 20 per user)
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS TABLE(deleted_count bigint, processed_users bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  total_deleted bigint := 0;
  user_count bigint := 0;
  user_rec RECORD;
  rows_deleted bigint;
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
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;
    total_deleted := total_deleted + rows_deleted;
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

COMMENT ON FUNCTION cleanup_old_clipboard_items_deep() IS
'Optimized daily cleanup: Keeps 20 most recent clips per user. Runs via pg_cron at 2 AM UTC. Zero overhead on inserts.';

-- ============================================================
-- STEP 3: pg_cron job is already scheduled, no changes needed
-- ============================================================

-- The existing cron job will now call our optimized function:
-- Job: cleanup-old-clips-daily
-- Schedule: 0 2 * * * (2 AM UTC daily)
-- Command: SELECT cleanup_old_clipboard_items_deep();

-- Verify the job exists
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-clips-daily') THEN
    RAISE WARNING 'pg_cron job "cleanup-old-clips-daily" not found. Please create it manually.';
  ELSE
    RAISE NOTICE 'pg_cron job "cleanup-old-clips-daily" is active and will use the new optimized function.';
  END IF;
END $$;

-- ============================================================
-- VERIFICATION & TESTING
-- ============================================================

-- To manually test the cleanup:
-- SELECT * FROM cleanup_old_clipboard_items_deep();

-- To check the cron job:
-- SELECT * FROM cron.job WHERE jobname = 'cleanup-old-clips-daily';

-- To see job history:
-- SELECT * FROM cron.job_run_details
-- WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'cleanup-old-clips-daily')
-- ORDER BY start_time DESC LIMIT 10;

-- To verify no triggers remain:
-- SELECT tgname, tgrelid::regclass FROM pg_trigger WHERE tgname LIKE '%cleanup%';
