-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 22:03:44 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix the cleanup function - VACUUM cannot run inside functions
-- Just delete old items, the VACUUM will happen during normal maintenance

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items_deep()
RETURNS void AS $$
BEGIN
  -- Delete items older than 30 days across all users
  DELETE FROM clipboard
  WHERE created_at < timezone('utc', now()) - interval '30 days';
  
  -- Log the number of rows deleted (optional)
  RAISE NOTICE 'Cleanup completed: deleted rows older than 30 days';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
