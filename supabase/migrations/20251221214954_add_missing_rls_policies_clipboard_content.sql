-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 21:49:54 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add missing INSERT policy for clipboard_content
CREATE POLICY "Users can insert their own clipboard content" ON clipboard_content
  FOR INSERT
  TO public
  WITH CHECK (auth.uid() = user_id);

-- Add missing DELETE policy for clipboard_content
CREATE POLICY "Users can delete their own clipboard content" ON clipboard_content
  FOR DELETE
  TO public
  USING (auth.uid() = user_id);

-- Add UPDATE policy in case we need to update content later
CREATE POLICY "Users can update their own clipboard content" ON clipboard_content
  FOR UPDATE
  TO public
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);
