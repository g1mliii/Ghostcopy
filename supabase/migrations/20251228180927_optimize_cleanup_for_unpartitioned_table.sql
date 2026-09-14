-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 18:09:27 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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
