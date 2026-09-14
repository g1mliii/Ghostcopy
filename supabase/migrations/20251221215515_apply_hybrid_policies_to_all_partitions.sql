-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-21 21:55:15 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Apply hybrid public-sharing policies to all partitions

-- clipboard_p0
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p0;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p0;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p0;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p0 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p0 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p0 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p1
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p1;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p1;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p1;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p1 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p1 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p1 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p2
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p2;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p2;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p2;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p2 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p2 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p2 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p3
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p3;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p3;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p3;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p3 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p3 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p3 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p4
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p4;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p4;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p4;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p4 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p4 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p4 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p5
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p5;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p5;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p5;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p5 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p5 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p5 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p6
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p6;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p6;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p6;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p6 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p6 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p6 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p7
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p7;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p7;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p7;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p7 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p7 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p7 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p8
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p8;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p8;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p8;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p8 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p8 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p8 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p9
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p9;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p9;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p9;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p9 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p9 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p9 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p10
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p10;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p10;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p10;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p10 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p10 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p10 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p11
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p11;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p11;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p11;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p11 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p11 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p11 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p12
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p12;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p12;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p12;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p12 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p12 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p12 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p13
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p13;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p13;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p13;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p13 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p13 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p13 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p14
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p14;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p14;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p14;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p14 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p14 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p14 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);

-- clipboard_p15
DROP POLICY IF EXISTS "Users can view their own clipboard items" ON clipboard_p15;
DROP POLICY IF EXISTS "Users can insert their own clipboard items" ON clipboard_p15;
DROP POLICY IF EXISTS "Users can delete their own clipboard items" ON clipboard_p15;
CREATE POLICY "Users can view their own or public clipboard items" ON clipboard_p15 FOR SELECT TO public USING ((SELECT auth.uid()) = user_id OR is_public = true);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p15 FOR INSERT TO public WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p15 FOR DELETE TO public USING ((SELECT auth.uid()) = user_id);
