-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 17:08:05 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize RLS policies to prevent auth.uid() re-evaluation per row
-- This improves query performance at scale
-- See: https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select

-- Drop existing policies
DROP POLICY IF EXISTS "Users can view own items" ON public.clipboard;
DROP POLICY IF EXISTS "Users can insert own items" ON public.clipboard;
DROP POLICY IF EXISTS "Users can delete own items" ON public.clipboard;

-- Recreate policies with optimized auth.uid() calls wrapped in SELECT
CREATE POLICY "Users can view own items" ON public.clipboard
  FOR SELECT
  USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can insert own items" ON public.clipboard
  FOR INSERT
  WITH CHECK ((select auth.uid()) = user_id);

CREATE POLICY "Users can delete own items" ON public.clipboard
  FOR DELETE
  USING ((select auth.uid()) = user_id);

-- Add UPDATE policy (currently missing, though updates aren't used in the app)
-- Including for completeness and future-proofing
CREATE POLICY "Users can update own items" ON public.clipboard
  FOR UPDATE
  USING ((select auth.uid()) = user_id)
  WITH CHECK ((select auth.uid()) = user_id);
