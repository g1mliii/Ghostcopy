-- Tighten RLS Policy: Remove Public Clipboard Sharing
--
-- Issue: RLS policy allows viewing items where is_public = true, but application
--        never sets is_public = true. This violates defense-in-depth principle.
--
-- Current Policy: user_id = auth.uid() OR is_public = true
-- New Policy: user_id = auth.uid() (strict user-only access)
--
-- Impact:
-- - Zero functional impact (nothing is currently public)
-- - Prevents accidental data leakage if is_public is set to true
-- - Enforces application behavior at database level
-- - Follows principle of least privilege

-- Drop the old permissive SELECT policy
DROP POLICY IF EXISTS users_view_own_or_public_clipboard ON clipboard;

-- Create strict user-only SELECT policy
CREATE POLICY users_view_own_clipboard_only ON clipboard
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Add CHECK constraint to prevent is_public from being set to true
-- This provides defense-in-depth: even if code has a bug, database prevents it
ALTER TABLE clipboard ADD CONSTRAINT enforce_private_only
  CHECK (is_public = false);

-- Update column comment to document this is enforced
COMMENT ON COLUMN clipboard.is_public IS
  'DEPRECATED: Must always be false. Public sharing is not supported for security. CHECK constraint enforced at database level.';

-- Verify the policy is in place
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'clipboard'
      AND policyname = 'users_view_own_clipboard_only'
  ) THEN
    RAISE EXCEPTION 'Failed to create users_view_own_clipboard_only policy';
  END IF;
END $$;
