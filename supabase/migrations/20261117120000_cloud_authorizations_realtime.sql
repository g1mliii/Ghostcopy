-- CloudAccessGuard follows a parent-managed account's own authorization row,
-- so a parent's withdrawal reaches the open app at once instead of at the next
-- lease check. RLS (own_cloud_authorization) limits each subscriber to its own
-- row. Enforcement does not depend on this feed: has_cloud_access() already
-- refuses a withdrawn account on every request.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
    AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
        AND tablename = 'cloud_authorizations') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.cloud_authorizations;
  END IF;
END $$;
