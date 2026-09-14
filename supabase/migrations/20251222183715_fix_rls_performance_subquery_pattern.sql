-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-22 18:37:15 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix RLS policies to use (SELECT auth.uid()) pattern for optimal performance
-- This prevents re-evaluation of auth.uid() for each row
-- PostgreSQL evaluates the subquery once and reuses the result

-- ========== FIX DEVICES TABLE ==========

DROP POLICY IF EXISTS "users_manage_own_devices" ON public.devices;

CREATE POLICY "users_manage_own_devices"
  ON public.devices
  FOR ALL
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

-- ========== FIX CLIPBOARD PARENT TABLE ==========

DROP POLICY IF EXISTS "users_view_own_or_public_clipboard" ON public.clipboard;
DROP POLICY IF EXISTS "users_insert_own_clipboard" ON public.clipboard;
DROP POLICY IF EXISTS "users_delete_own_clipboard" ON public.clipboard;
DROP POLICY IF EXISTS "users_update_own_clipboard" ON public.clipboard;

CREATE POLICY "users_view_own_or_public_clipboard"
  ON public.clipboard
  FOR SELECT
  TO authenticated
  USING (user_id = (SELECT auth.uid()) OR is_public = true);

CREATE POLICY "users_insert_own_clipboard"
  ON public.clipboard
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY "users_delete_own_clipboard"
  ON public.clipboard
  FOR DELETE
  TO authenticated
  USING (user_id = (SELECT auth.uid()));

CREATE POLICY "users_update_own_clipboard"
  ON public.clipboard
  FOR UPDATE
  TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));
