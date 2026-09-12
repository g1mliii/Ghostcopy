-- Sync Strict RLS Policies to All Partitions
--
-- After tightening the main table's RLS policy, we need to sync to all partitions.
-- The old policy name still appears on partitions in pg_policies.

-- Drop old policies from all partitions
DO $$
DECLARE
  partition_name text;
BEGIN
  FOR partition_name IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename LIKE 'clipboard_p%'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS users_view_own_or_public_clipboard ON %I', partition_name);
  END LOOP;
END $$;

-- Create new strict policies on all partitions
DO $$
DECLARE
  partition_name text;
BEGIN
  FOR partition_name IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
      AND tablename LIKE 'clipboard_p%'
  LOOP
    -- SELECT policy: user can only view their own items
    EXECUTE format('
      CREATE POLICY users_view_own_clipboard_only ON %I
        FOR SELECT TO authenticated
        USING (user_id = auth.uid())
    ', partition_name);
  END LOOP;
END $$;

-- Verify all partitions have the new policy
DO $$
DECLARE
  partition_count integer;
  policy_count integer;
BEGIN
  -- Count partitions
  SELECT COUNT(*) INTO partition_count
  FROM pg_tables
  WHERE schemaname = 'public'
    AND tablename LIKE 'clipboard_p%';

  -- Count new policies on partitions
  SELECT COUNT(*) INTO policy_count
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename LIKE 'clipboard_p%'
    AND policyname = 'users_view_own_clipboard_only';

  IF partition_count != policy_count THEN
    RAISE EXCEPTION 'Policy sync failed: % partitions but only % policies', partition_count, policy_count;
  END IF;

  RAISE NOTICE 'Successfully synced strict RLS policies to % partitions', partition_count;
END $$;
