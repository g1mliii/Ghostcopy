-- Fix app_config RLS policy to allow anonymous and authenticated users to read
-- The original policy denied access; we need to explicitly grant READ access to all users

-- Drop the overly restrictive policy
DROP POLICY IF EXISTS app_config_read_all ON app_config;

-- Create new policy that allows all users (authenticated and anonymous) to read
CREATE POLICY app_config_read_for_all ON app_config
  FOR SELECT
  USING (true);

-- Keep the admin-only policy for modifications (no updates from app)
-- This ensures only Supabase admins can modify feature flags via dashboard
