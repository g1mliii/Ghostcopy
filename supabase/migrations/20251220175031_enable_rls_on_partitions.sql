-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:50:31 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Enable RLS on all partition tables
ALTER TABLE clipboard_p0 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p1 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p3 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p4 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p5 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p6 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p7 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p8 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p9 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p10 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p11 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p12 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p13 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p14 ENABLE ROW LEVEL SECURITY;
ALTER TABLE clipboard_p15 ENABLE ROW LEVEL SECURITY;

-- Create RLS policies on all partitions (inherited from parent, but let's be explicit)
CREATE POLICY "Users can view their own clipboard items" ON clipboard_p0
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p0
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p0
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p1
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p1
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p1
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p2
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p2
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p2
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p3
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p3
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p3
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p4
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p4
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p4
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p5
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p5
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p5
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p6
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p6
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p6
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p7
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p7
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p7
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p8
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p8
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p8
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p9
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p9
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p9
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p10
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p10
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p10
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p11
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p11
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p11
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p12
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p12
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p12
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p13
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p13
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p13
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p14
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p14
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p14
FOR DELETE USING ((select auth.uid()) = user_id);

CREATE POLICY "Users can view their own clipboard items" ON clipboard_p15
FOR SELECT USING ((select auth.uid()) = user_id);
CREATE POLICY "Users can insert their own clipboard items" ON clipboard_p15
FOR INSERT WITH CHECK ((select auth.uid()) = user_id);
CREATE POLICY "Users can delete their own clipboard items" ON clipboard_p15
FOR DELETE USING ((select auth.uid()) = user_id);
