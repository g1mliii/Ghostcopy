-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 17:34:24 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Create a function that automatically cleans up old clipboard items
-- This runs directly in the database for maximum performance
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Delete old items for this user, keeping only the 10 most recent
  -- Uses a subquery to efficiently identify items to delete
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
$$ LANGUAGE plpgsql;

-- Create trigger that fires AFTER each insert
-- This ensures cleanup happens automatically without client intervention
CREATE TRIGGER trigger_cleanup_old_clipboard_items
  AFTER INSERT ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_old_clipboard_items();

-- Add comment for documentation
COMMENT ON FUNCTION cleanup_old_clipboard_items() IS 
  'Automatically deletes old clipboard items, keeping only the 10 most recent per user. Runs on every insert for optimal performance.';
