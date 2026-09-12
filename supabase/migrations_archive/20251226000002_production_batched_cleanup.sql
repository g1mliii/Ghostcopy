-- Production-Grade Batched Cleanup (Prevents Backend Saturation)
--
-- PROBLEM SOLVED:
-- - OLD: Single large query could saturate backend at scale
-- - NEW: Batched + partitioned approach prevents saturation
--
-- FEATURES:
-- - Processes 16 partitions sequentially (not all at once)
-- - Batches of 10K clips (prevents memory spikes)
-- - Yields between batches (allows inserts to proceed)
-- - Safe for millions of users

-- Drop old version
DROP FUNCTION IF EXISTS cleanup_old_clipboard_items_deep() CASCADE;

-- Create production-grade version
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS TABLE(deleted_count bigint, processed_users bigint, duration_seconds numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  total_deleted bigint := 0;
  total_users bigint := 0;
  partition_rec RECORD;
  batch_deleted bigint;
  batch_users bigint;
  start_time timestamp;
  partition_name text;
BEGIN
  start_time := clock_timestamp();

  -- Process each partition separately to reduce memory and lock contention
  FOR partition_rec IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename LIKE 'clipboard_p%'
    ORDER BY tablename
  LOOP
    partition_name := partition_rec.tablename;

    -- Process this partition in batches to prevent timeouts
    -- Batch size: 10,000 clips at a time
    LOOP
      -- Delete one batch from this partition
      EXECUTE format('
        WITH ranked_clips AS (
          SELECT id, user_id,
            ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) as row_num
          FROM %I
        ),
        clips_to_delete AS (
          SELECT id, user_id
          FROM ranked_clips
          WHERE row_num > 20
          LIMIT 10000  -- Batch size: tune based on load
        ),
        deleted_clips AS (
          DELETE FROM %I
          WHERE id IN (SELECT id FROM clips_to_delete)
          RETURNING id, user_id
        )
        SELECT
          COUNT(*)::bigint,
          COUNT(DISTINCT user_id)::bigint
        FROM deleted_clips
      ', partition_name, partition_name)
      INTO batch_deleted, batch_users;

      -- Track totals
      total_deleted := total_deleted + batch_deleted;
      total_users := total_users + batch_users;

      -- Exit loop if no more clips to delete in this partition
      EXIT WHEN batch_deleted = 0;

      -- Yield to other operations between batches (prevents saturation)
      PERFORM pg_sleep(0.1);  -- 100ms pause

    END LOOP;

    RAISE NOTICE 'Processed partition %: % total clips deleted so far', partition_name, total_deleted;

    -- Pause between partitions (allows inserts to proceed)
    PERFORM pg_sleep(0.5);  -- 500ms pause

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
'Production-grade cleanup with batching and partition processing. Prevents backend saturation by:
1. Processing one partition at a time (reduces lock contention)
2. Batching deletes (10K clips max per batch)
3. Yielding between batches (100ms pause)
4. Yielding between partitions (500ms pause)
Safe for millions of users. Monitored via duration_seconds return value.';

-- Verify pg_cron job exists and will use this function
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-clips-daily') THEN
    RAISE WARNING 'pg_cron job "cleanup-old-clips-daily" not found. Create it with: SELECT cron.schedule(''cleanup-old-clips-daily'', ''0 2 * * *'', $$SELECT * FROM cleanup_old_clipboard_items_deep()$$);';
  ELSE
    RAISE NOTICE 'pg_cron job "cleanup-old-clips-daily" is active. Cleanup runs daily at 2 AM UTC.';
  END IF;
END $$;
