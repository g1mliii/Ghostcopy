-- Migration: Fix critical privilege escalation vulnerabilities in SECURITY DEFINER functions
-- Issue: cleanup_user_data and cleanup_old_clipboard_items lack authorization checks
-- Impact: Any authenticated user could delete any other user's data
-- Fix: Add auth.uid() checks to ensure users can only delete their own data

-- ============================================================================
-- Fix #1: cleanup_user_data - Add authorization check
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_user_data(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- CRITICAL SECURITY FIX: Verify caller owns this user_id
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized: Cannot delete data for other users';
  END IF;

  -- Delete clipboard items for the user
  DELETE FROM clipboard WHERE user_id = p_user_id;

  -- Delete device records for the user
  DELETE FROM devices WHERE user_id = p_user_id;

  -- Delete passphrases/encryption keys for the user (if table exists)
  -- Note: Table may not exist in all environments
  BEGIN
    DELETE FROM passphrases WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN
    -- Ignore if table doesn't exist
    NULL;
  END;

  -- Delete mobile link tokens for the user
  DELETE FROM mobile_link_tokens WHERE user_id = p_user_id;
END;
$$;

COMMENT ON FUNCTION cleanup_user_data(uuid) IS
  'Deletes all data for a user. SECURITY: Only allows users to delete their own data via auth.uid() check.';


-- ============================================================================
-- Fix #2: cleanup_old_clipboard_items - Add authorization check
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items(p_user_id uuid, p_keep_count integer DEFAULT 15)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_to_delete RECORD;
BEGIN
  -- CRITICAL SECURITY FIX: Verify caller owns this user_id
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized: Cannot delete clipboard items for other users';
  END IF;

  -- Validate p_keep_count parameter
  IF p_keep_count < 0 THEN
    RAISE EXCEPTION 'Invalid parameter: p_keep_count must be >= 0';
  END IF;

  -- Delete old clipboard items AND their storage files
  FOR v_to_delete IN
    SELECT id, storage_path
    FROM clipboard
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    OFFSET p_keep_count
  LOOP
    -- Delete storage file if it exists (images/files)
    IF v_to_delete.storage_path IS NOT NULL THEN
      BEGIN
        PERFORM storage.delete_object('clipboard-files', v_to_delete.storage_path);
      EXCEPTION WHEN OTHERS THEN
        -- Log but don't fail - storage file may already be gone
        RAISE WARNING 'Failed to delete storage file %: %', v_to_delete.storage_path, SQLERRM;
      END;
    END IF;

    -- Delete the clipboard record
    DELETE FROM clipboard WHERE id = v_to_delete.id;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION cleanup_old_clipboard_items(uuid, integer) IS
  'Deletes old clipboard items for a user, keeping only the most recent N items. SECURITY: Only allows users to delete their own items via auth.uid() check.';


-- ============================================================================
-- Verification
-- ============================================================================
-- The functions still have EXECUTE granted to PUBLIC/anon/authenticated,
-- but now they enforce authorization internally via auth.uid() checks.
-- This is the correct pattern for SECURITY DEFINER functions that need
-- to perform privileged operations (like storage deletion) while maintaining
-- user-level access control.
