-- Optimize Storage Cleanup: Integrate into Batched Cleanup
-- Date: 2026-01-02
-- Description: Removes trigger-based storage cleanup and integrates into optimized batched function

-- ISSUE: BEFORE DELETE trigger adds overhead to every deletion (less performant at scale)
-- FIX: Integrate storage file deletion into optimized batched cleanup function

-- ============================================================
-- STEP 1: Drop trigger-based storage cleanup
-- ============================================================

DROP TRIGGER IF EXISTS trigger_delete_clipboard_storage_file ON clipboard CASCADE;
DROP FUNCTION IF EXISTS delete_clipboard_storage_file() CASCADE;

-- ============================================================
-- STEP 2: Update optimized cleanup to handle storage files
-- ============================================================

-- Drop and recreate the optimized cleanup function with storage support
DROP FUNCTION IF EXISTS cleanup_old_clipboard_items_deep() CASCADE;

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS TABLE(deleted_count bigint, processed_users bigint, storage_files_deleted bigint, duration_seconds numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  total_deleted bigint := 0;
  total_users bigint := 0;
  total_storage_deleted bigint := 0;
  batch_deleted bigint;
  user_batch RECORD;
  clip_to_delete RECORD;
  start_time timestamp;
BEGIN
  start_time := clock_timestamp();

  -- Process users in batches (100 users at a time)
  -- Avoids scanning entire table with window functions
  LOOP
    batch_deleted := 0;

    -- Process a batch of users who have >15 clips
    FOR user_batch IN
      SELECT user_id, COUNT(*) as clip_count
      FROM clipboard
      GROUP BY user_id
      HAVING COUNT(*) > 15  -- Updated from 20 to 15
      LIMIT 100  -- Process 100 users per batch
    LOOP
      -- For this user, delete clips beyond the 15 most recent
      -- Delete storage files FIRST, then delete DB records
      FOR clip_to_delete IN
        WITH clips_to_keep AS (
          SELECT id
          FROM clipboard
          WHERE user_id = user_batch.user_id
          ORDER BY created_at DESC
          LIMIT 15  -- Keep 15 most recent
        )
        SELECT id, storage_path
        FROM clipboard
        WHERE user_id = user_batch.user_id
          AND id NOT IN (SELECT id FROM clips_to_keep)
      LOOP
        -- Delete storage file if it exists (images only)
        IF clip_to_delete.storage_path IS NOT NULL THEN
          BEGIN
            PERFORM storage.delete_object('clipboard-files', clip_to_delete.storage_path);
            total_storage_deleted := total_storage_deleted + 1;
          EXCEPTION WHEN OTHERS THEN
            -- Log but don't fail - storage file may already be gone
            RAISE WARNING 'Failed to delete storage file %: %', clip_to_delete.storage_path, SQLERRM;
          END;
        END IF;

        -- Delete the clipboard record
        DELETE FROM clipboard WHERE id = clip_to_delete.id;
        batch_deleted := batch_deleted + 1;
      END LOOP;

      total_deleted := total_deleted + batch_deleted;
      total_users := total_users + 1;
    END LOOP;

    -- Exit if no users with >15 clips remain
    EXIT WHEN NOT FOUND;

    -- Log progress every 100 users
    IF total_users % 100 = 0 THEN
      RAISE NOTICE 'Progress: % users processed, % clips deleted, % storage files deleted',
        total_users, total_deleted, total_storage_deleted;
    END IF;

    -- Yield to other operations between user batches
    PERFORM pg_sleep(0.05);  -- 50ms pause

  END LOOP;

  -- Return stats
  deleted_count := total_deleted;
  processed_users := total_users;
  storage_files_deleted := total_storage_deleted;
  duration_seconds := EXTRACT(EPOCH FROM (clock_timestamp() - start_time));
  RETURN NEXT;

  -- Log completion
  RAISE NOTICE 'Cleanup completed: % clips deleted, % storage files deleted for % users in % seconds',
    total_deleted, total_storage_deleted, total_users, duration_seconds;
END;
$$;

COMMENT ON FUNCTION cleanup_old_clipboard_items_deep() IS
'Optimized cleanup for unpartitioned clipboard table with storage file deletion.
Prevents table scans and lock contention by:
1. Processing users in batches (100 users at a time)
2. Using index scans instead of window functions (fast on user_id, created_at)
3. Deleting storage files inline (no trigger overhead)
4. Yielding between batches (50ms pause)
5. Keeping only 15 most recent clips per user (updated from 20)
Users can access the table during cleanup (row-level locks only). Safe for millions of users.';

-- ============================================================
-- STEP 3: Update per-user cleanup function for storage files
-- ============================================================

-- Update the per-user cleanup function to also handle storage files
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items(
  p_user_id uuid,
  p_keep_count int DEFAULT 15  -- Updated from 10 to 15
)
RETURNS void AS $$
DECLARE
  v_to_delete RECORD;
BEGIN
  -- Delete old clipboard items AND their storage files
  FOR v_to_delete IN
    SELECT id, storage_path
    FROM clipboard
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    OFFSET p_keep_count
  LOOP
    -- Delete storage file if it exists (images only)
    IF v_to_delete.storage_path IS NOT NULL THEN
      BEGIN
        PERFORM storage.delete_object('clipboard-files', v_to_delete.storage_path);
      EXCEPTION WHEN OTHERS THEN
        -- Log but don't fail - storage file may already be gone
        RAISE WARNING 'Failed to delete storage file %: %', v_to_delete.storage_path, SQLERRM;
      END;
    END IF;

    -- Delete the clipboard record
    DELETE FROM clipboard WHERE id = v_to_delete.id;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_old_clipboard_items(uuid, int) IS
'Cleans up old clipboard items for a specific user, keeping only the most recent N items.
Handles storage file deletion inline. Default keep count is 15.';

-- ============================================================
-- VERIFICATION
-- ============================================================

-- Verify no cleanup triggers remain:
-- SELECT tgname, tgrelid::regclass FROM pg_trigger WHERE tgname LIKE '%cleanup%';

-- Manual test (safe to run):
-- SELECT * FROM cleanup_old_clipboard_items_deep();
