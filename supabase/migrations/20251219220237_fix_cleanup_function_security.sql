-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 22:02:37 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix security warning: Set search_path for cleanup function
-- This prevents search_path injection attacks

-- Drop and recreate the function with proper security settings
DROP FUNCTION IF EXISTS cleanup_old_clipboard_items() CASCADE;

CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM clipboard
  WHERE user_id = NEW.user_id
  AND id NOT IN (
    SELECT id
    FROM clipboard
    WHERE user_id = NEW.user_id
    ORDER BY created_at DESC
    LIMIT 10
  );
  
  RETURN NEW;
END;
$$;

-- Recreate the trigger
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard;

CREATE TRIGGER trigger_cleanup_old_clipboard_items
  AFTER INSERT ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_old_clipboard_items();
