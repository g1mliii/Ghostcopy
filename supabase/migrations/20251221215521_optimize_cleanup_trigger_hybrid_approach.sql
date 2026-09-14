-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 21:55:21 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Replace the heavy cleanup function with lightweight version
-- Heavy cleanup will run as a scheduled background job instead

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Light cleanup: Only delete items older than 2 hours that exceed 20 recent items
  -- This prevents unbounded growth in a single transaction
  -- Deep cleanup (>30 days) happens in background job
  DELETE FROM clipboard
  WHERE user_id = NEW.user_id
  AND created_at < timezone('utc', now()) - interval '2 hours'
  AND id NOT IN (
    SELECT id
    FROM clipboard
    WHERE user_id = NEW.user_id
    ORDER BY created_at DESC
    LIMIT 20
  );
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Create deep cleanup function for background jobs (runs periodically)
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS void AS $$
BEGIN
  -- Delete items older than 30 days across all users
  -- This is safe to run in background without locking inserts
  DELETE FROM clipboard
  WHERE created_at < timezone('utc', now()) - interval '30 days';
  
  -- Vacuum to reclaim space from deleted rows
  VACUUM ANALYZE clipboard;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
