-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-22 18:37:25 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix RLS policies on all 16 clipboard partitions
-- Use (SELECT auth.uid()) pattern to prevent re-evaluation for each row

DO $$
DECLARE
    partition_name text;
BEGIN
    -- Loop through all clipboard partitions (p0 to p15)
    FOR i IN 0..15 LOOP
        partition_name := 'clipboard_p' || i;
        
        -- Drop old policies
        EXECUTE format('DROP POLICY IF EXISTS "users_view_own_or_public_clipboard" ON public.%I', partition_name);
        EXECUTE format('DROP POLICY IF EXISTS "users_insert_own_clipboard" ON public.%I', partition_name);
        EXECUTE format('DROP POLICY IF EXISTS "users_delete_own_clipboard" ON public.%I', partition_name);
        EXECUTE format('DROP POLICY IF EXISTS "users_update_own_clipboard" ON public.%I', partition_name);
        
        -- Create optimized policies with subquery pattern
        EXECUTE format('CREATE POLICY "users_view_own_or_public_clipboard" ON public.%I FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()) OR is_public = true)', partition_name);
        EXECUTE format('CREATE POLICY "users_insert_own_clipboard" ON public.%I FOR INSERT TO authenticated WITH CHECK (user_id = (SELECT auth.uid()))', partition_name);
        EXECUTE format('CREATE POLICY "users_delete_own_clipboard" ON public.%I FOR DELETE TO authenticated USING (user_id = (SELECT auth.uid()))', partition_name);
        EXECUTE format('CREATE POLICY "users_update_own_clipboard" ON public.%I FOR UPDATE TO authenticated USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()))', partition_name);
    END LOOP;
END $$;
