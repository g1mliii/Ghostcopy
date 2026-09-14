-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 21:51:28 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize clipboard table policies
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard;

CREATE POLICY "Users can view their own clipboard items" ON clipboard
  FOR SELECT
  TO public
  USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can insert their own clipboard items" ON clipboard
  FOR INSERT
  TO public
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can delete their own clipboard items" ON clipboard
  FOR DELETE
  TO public
  USING ((SELECT auth.uid()) = user_id);
