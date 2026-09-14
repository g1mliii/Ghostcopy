-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 18:11:22 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize RLS Policies: Remove Subquery Wrapper
--
-- ISSUE: Current policies use (user_id = (SELECT auth.uid()))
--        The SELECT wrapper can cause InitPlan execution overhead
--
-- FIX: Use user_id = auth.uid() directly
--      auth.uid() is STABLE (cached per query) so this is safe and faster
--
-- PERFORMANCE IMPACT:
-- - Removes subquery overhead on every query
-- - Planner can optimize direct comparisons better
-- - Especially important for high-frequency SELECT queries

-- Drop existing policies
DROP POLICY IF EXISTS users_view_own_clipboard_only ON clipboard;
DROP POLICY IF EXISTS users_insert_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_update_own_clipboard ON clipboard;
DROP POLICY IF EXISTS users_delete_own_clipboard ON clipboard;

-- Recreate with optimized pattern (no SELECT wrapper)
CREATE POLICY users_view_own_clipboard_only ON clipboard
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY users_insert_own_clipboard ON clipboard
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY users_update_own_clipboard ON clipboard
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY users_delete_own_clipboard ON clipboard
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- Add comments for documentation
COMMENT ON POLICY users_view_own_clipboard_only ON clipboard IS
'Allow users to view only their own clipboard items. Optimized: direct auth.uid() call without subquery wrapper.';

COMMENT ON POLICY users_insert_own_clipboard ON clipboard IS
'Allow users to insert only their own clipboard items. Optimized: direct auth.uid() call without subquery wrapper.';

COMMENT ON POLICY users_update_own_clipboard ON clipboard IS
'Allow users to update only their own clipboard items. Optimized: direct auth.uid() call without subquery wrapper.';

COMMENT ON POLICY users_delete_own_clipboard ON clipboard IS
'Allow users to delete only their own clipboard items. Optimized: direct auth.uid() call without subquery wrapper.';
