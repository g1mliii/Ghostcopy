-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-22 18:31:38 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Drop existing inefficient policies that use (SELECT auth.uid() AS uid)
DROP POLICY IF EXISTS "Users can view their own or public clipboard items" ON public.clipboard;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON public.clipboard;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON public.clipboard;

-- Recreate optimized policies using auth.uid() directly (STABLE function, called once per statement)
-- This is much more performant than (SELECT auth.uid() AS uid) which creates a subquery

-- SELECT policy: Users can view their own items OR public items
CREATE POLICY "users_view_own_or_public_clipboard"
  ON public.clipboard
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid() OR is_public = true);

-- INSERT policy: Users can only insert with their own user_id
CREATE POLICY "users_insert_own_clipboard"
  ON public.clipboard
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

-- DELETE policy: Users can only delete their own items
CREATE POLICY "users_delete_own_clipboard"
  ON public.clipboard
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

-- UPDATE policy: Users can only update their own items (if needed in future)
CREATE POLICY "users_update_own_clipboard"
  ON public.clipboard
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
