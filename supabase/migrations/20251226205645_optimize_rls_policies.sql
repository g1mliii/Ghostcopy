-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-26 20:56:45 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize RLS policies to use (select auth.uid()) instead of auth.uid()
-- This prevents re-evaluation of auth.uid() for each row, improving query performance
-- See: https://supabase.com/docs/guides/database/postgres/row-level-security#call-functions-with-select

-- Main clipboard table
DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

-- Partitioned tables (clipboard_p0 through clipboard_p15)
DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p0;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p0
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p1;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p1
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p2;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p2
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p3;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p3
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p4;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p4
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p5;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p5
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p6;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p6
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p7;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p7
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p8;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p8
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p9;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p9
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p10;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p10
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p11;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p11
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p12;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p12
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p13;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p13
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p14;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p14
  FOR ALL
  USING (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS users_view_own_clipboard_only ON public.clipboard_p15;
CREATE POLICY users_view_own_clipboard_only ON public.clipboard_p15
  FOR ALL
  USING (user_id = (SELECT auth.uid()));
