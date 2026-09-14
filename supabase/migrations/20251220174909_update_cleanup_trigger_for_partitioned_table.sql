-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:49:09 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop old trigger (references old table)
DROP TRIGGER IF EXISTS trigger_cleanup_old_clipboard_items ON clipboard;

-- Recreate trigger with updated function for new schema
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Delete entries where:
  -- 1. Older than 30 days, OR
  -- 2. Beyond last 10 items for this user
  DELETE FROM clipboard
  WHERE user_id = NEW.user_id
  AND (
    created_at < timezone('utc', now()) - interval '30 days'
    OR
    id NOT IN (
      SELECT id
      FROM clipboard
      WHERE user_id = NEW.user_id
      ORDER BY created_at DESC
      LIMIT 10
    )
  );
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach trigger to new table
CREATE TRIGGER trigger_cleanup_old_clipboard_items
AFTER INSERT ON clipboard
FOR EACH ROW
EXECUTE FUNCTION cleanup_old_clipboard_items();
