-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:50:36 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop old RLS policies with unoptimized auth.uid() calls
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard;

-- Recreate with optimized (select auth.uid()) to prevent row-by-row re-evaluation
CREATE POLICY "Users can view their own clipboard items"
ON clipboard
FOR SELECT
USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can insert their own clipboard items"
ON clipboard
FOR INSERT
WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY "Users can delete their own clipboard items"
ON clipboard
FOR DELETE
USING ((select auth.uid()) = user_id);

-- Also optimize clipboard_content table
DROP POLICY IF EXISTS "Users can view their own clipboard content" ON clipboard_content;

CREATE POLICY "Users can view their own clipboard content"
ON clipboard_content
FOR SELECT
USING ((select auth.uid()) = user_id);

-- Fix the cleanup function to have immutable search_path
ALTER FUNCTION cleanup_old_clipboard_items() SET search_path = public;
