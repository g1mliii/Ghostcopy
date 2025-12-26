-- Drop duplicate indexes on clipboard partitions
--
-- Issue: Supabase Advisor detected 16 duplicate indexes wasting storage and slowing writes
-- Pattern: clipboard_pN_user_id_created_at_idx + clipboard_pN_user_id_created_at_idx1
--
-- Root Cause: Parent partitioned index created duplicate child indexes
--
-- Solution: Drop the parent index idx_clipboard_user_created with CASCADE
-- This automatically removes all 16 child partition indexes (idx1 versions)
--
-- Impact:
-- - Reduces index storage by ~50% on user_id+created_at indexes
-- - Improves INSERT/UPDATE performance (fewer indexes to update)
-- - No impact on query performance (original indexes remain)

-- Drop the parent partitioned index which will cascade to all child partitions
DROP INDEX IF EXISTS idx_clipboard_user_created CASCADE;

-- Verify remaining indexes
-- Run this query after migration to confirm only one index per partition:
--
-- SELECT
--   schemaname,
--   tablename,
--   indexname
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND tablename LIKE 'clipboard_p%'
--   AND indexname LIKE '%user_id_created_at%'
-- ORDER BY tablename, indexname;
--
-- Expected result: 16 rows (one per partition, ending with _idx, not _idx1)

-- Add comment for documentation
COMMENT ON SCHEMA public IS 'Dropped 16 duplicate indexes on clipboard partitions to improve write performance and reduce storage overhead.';
