-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-26 17:24:57 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop duplicate partitioned index on clipboard table
--
-- Issue: Two identical partitioned indexes exist on clipboard(user_id, created_at DESC)
--   1. idx_clipboard_user_created (with children clipboard_pN_user_id_created_at_idx)
--   2. idx_clipboard_user_created_desc (with children clipboard_pN_user_id_created_at_idx1)
--
-- Both indexes are identical and serve the same purpose.
-- Dropping idx_clipboard_user_created_desc will automatically drop all 16 child indexes.
--
-- Impact:
--   - Reduces index storage by 50% on this index
--   - Improves INSERT/UPDATE performance (one less index to maintain)
--   - No query performance impact (identical index remains)

DROP INDEX IF EXISTS idx_clipboard_user_created_desc CASCADE;
