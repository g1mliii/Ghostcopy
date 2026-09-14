-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 16:59:28 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize RLS policies to prevent re-evaluation of auth.uid() for each row
-- This improves query performance by using (select auth.uid()) instead of auth.uid()

-- Drop existing policies
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard;
DROP POLICY IF EXISTS users_insert_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_update_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_delete_own_clipboard ON clipboard;

-- Recreate policies with optimized auth.uid() calls
CREATE POLICY users_view_own_clipboard_only ON clipboard
  FOR SELECT TO authenticated
  USING (user_id = (select auth.uid()));

CREATE POLICY users_insert_own_clipboard ON clipboard
  FOR INSERT TO authenticated
  WITH CHECK (user_id = (select auth.uid()));

CREATE POLICY users_update_own_clipboard ON clipboard
  FOR UPDATE TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

CREATE POLICY users_delete_own_clipboard ON clipboard
  FOR DELETE TO authenticated
  USING (user_id = (select auth.uid()));
