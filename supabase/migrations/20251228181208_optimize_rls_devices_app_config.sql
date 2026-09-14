-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-28 18:12:08 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Optimize RLS Policies: devices and app_config tables
--
-- ISSUE: Same as clipboard - using (SELECT auth.uid()) and (SELECT auth.role())
--        The SELECT wrapper adds unnecessary overhead
--
-- FIX: Use auth.uid() and auth.role() directly
--
-- TABLES AFFECTED:
-- - devices: user_id = auth.uid()
-- - app_config: auth.role() = 'authenticated'

-- ============================================================
-- DEVICES TABLE
-- ============================================================

DROP POLICY IF EXISTS users_manage_own_devices ON devices;

-- Split the ALL policy into individual policies for better control
CREATE POLICY users_view_own_devices ON devices
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY users_insert_own_devices ON devices
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY users_update_own_devices ON devices
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY users_delete_own_devices ON devices
  FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

COMMENT ON POLICY users_view_own_devices ON devices IS
'Allow users to view only their own devices. Optimized: direct auth.uid() call.';

COMMENT ON POLICY users_insert_own_devices ON devices IS
'Allow users to insert only their own devices. Optimized: direct auth.uid() call.';

COMMENT ON POLICY users_update_own_devices ON devices IS
'Allow users to update only their own devices. Optimized: direct auth.uid() call.';

COMMENT ON POLICY users_delete_own_devices ON devices IS
'Allow users to delete only their own devices. Optimized: direct auth.uid() call.';

-- ============================================================
-- APP_CONFIG TABLE
-- ============================================================

DROP POLICY IF EXISTS app_config_read_all ON app_config;
DROP POLICY IF EXISTS app_config_write_auth ON app_config;
DROP POLICY IF EXISTS app_config_update_auth ON app_config;
DROP POLICY IF EXISTS app_config_delete_auth ON app_config;

-- Recreate with optimized pattern (no SELECT wrapper)
CREATE POLICY app_config_read_all ON app_config
  FOR SELECT
  USING (true);  -- All users can read app config

CREATE POLICY app_config_write_auth ON app_config
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY app_config_update_auth ON app_config
  FOR UPDATE
  TO authenticated
  WITH CHECK (auth.role() = 'authenticated');

CREATE POLICY app_config_delete_auth ON app_config
  FOR DELETE
  TO authenticated
  USING (auth.role() = 'authenticated');

COMMENT ON POLICY app_config_read_all ON app_config IS
'Allow all users to read app configuration.';

COMMENT ON POLICY app_config_write_auth ON app_config IS
'Allow authenticated users to insert app config. Optimized: direct auth.role() call.';

COMMENT ON POLICY app_config_update_auth ON app_config IS
'Allow authenticated users to update app config. Optimized: direct auth.role() call.';

COMMENT ON POLICY app_config_delete_auth ON app_config IS
'Allow authenticated users to delete app config. Optimized: direct auth.role() call.';
