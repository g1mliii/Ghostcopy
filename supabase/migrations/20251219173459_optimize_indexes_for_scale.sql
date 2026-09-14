-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 17:34:59 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop old individual indexes that are less efficient
DROP INDEX IF EXISTS idx_clipboard_user_id;
DROP INDEX IF EXISTS idx_clipboard_user_created;

-- Create optimized composite index for our exact query pattern
-- This single index handles both filtering by user_id AND sorting by created_at
-- Much more efficient than separate indexes, especially at scale
CREATE INDEX idx_clipboard_user_created_desc 
ON clipboard(user_id, created_at DESC);

-- Add index for real-time subscriptions (broadcast optimization)
-- This helps Supabase efficiently filter real-time events by user_id
CREATE INDEX idx_clipboard_realtime 
ON clipboard(user_id, id);

-- Statistics comment
COMMENT ON INDEX idx_clipboard_user_created_desc IS 
  'Composite index optimized for fetching user clipboard history sorted by recency. Supports efficient queries for millions of users.';

COMMENT ON INDEX idx_clipboard_realtime IS 
  'Optimized for real-time subscription filtering by user_id. Improves broadcast performance at scale.';
