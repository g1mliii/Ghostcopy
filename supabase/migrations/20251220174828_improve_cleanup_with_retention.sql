-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:48:28 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Improve cleanup function to enforce both last-10 AND 30-day retention
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items()
RETURNS TRIGGER AS $$
BEGIN
  -- Delete entries that are:
  -- 1. Older than 30 days, OR
  -- 2. Beyond the last 10 for this user
  DELETE FROM clipboard
  WHERE user_id = NEW.user_id
  AND (
    -- Rule 1: Older than 30 days
    created_at < timezone('utc', now()) - interval '30 days'
    OR
    -- Rule 2: Beyond last 10 items
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
