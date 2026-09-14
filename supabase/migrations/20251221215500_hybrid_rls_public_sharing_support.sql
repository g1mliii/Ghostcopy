-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 21:55:00 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add public sharing support while keeping anon user isolation
-- This allows authenticated users to optionally share clips publicly
-- while keeping anon users isolated to their own data

-- Update clipboard policies to support public rows
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard;

-- SELECT: Own items OR public items
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard
  FOR SELECT
  TO public
  USING ((SELECT auth.uid()) = user_id OR is_public = true);

-- INSERT: Own items only
CREATE POLICY "Users can insert their own clipboard items" ON clipboard
  FOR INSERT
  TO public
  WITH CHECK ((SELECT auth.uid()) = user_id);

-- DELETE: Own items only
CREATE POLICY "Users can delete their own clipboard items" ON clipboard
  FOR DELETE
  TO public
  USING ((SELECT auth.uid()) = user_id);

-- Same for clipboard_content table
DROP POLICY IF EXISTS "Users can view their own clipboard content" ON clipboard_content;
DROP POLICY IF EXISTS "Users can insert their own clipboard content" ON clipboard_content;
DROP POLICY IF EXISTS "Users can delete their own clipboard content" ON clipboard_content;
DROP POLICY IF EXISTS "Users can update their own clipboard content" ON clipboard_content;

-- For content, only owner can read (no public sharing of raw content)
CREATE POLICY "Users can view their own clipboard content" ON clipboard_content
  FOR SELECT
  TO public
  USING ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can insert their own clipboard content" ON clipboard_content
  FOR INSERT
  TO public
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can update their own clipboard content" ON clipboard_content
  FOR UPDATE
  TO public
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Users can delete their own clipboard content" ON clipboard_content
  FOR DELETE
  TO public
  USING ((SELECT auth.uid()) = user_id);
