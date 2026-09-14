-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-26 17:32:39 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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

-- Add comment for documentation
COMMENT ON SCHEMA public IS 'Dropped 16 duplicate indexes on clipboard partitions to improve write performance and reduce storage overhead.';
