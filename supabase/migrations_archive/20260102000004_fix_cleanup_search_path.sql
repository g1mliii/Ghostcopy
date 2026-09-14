-- Fix Supabase Advisor: Function Search Path Mutable
-- Date: 2026-01-02
-- Description: Add SET search_path to cleanup functions for security

-- Fix cleanup_old_clipboard_items function
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items(
  p_user_id uuid,
  p_keep_count int DEFAULT 15
)
RETURNS void AS $$
DECLARE
  v_to_delete RECORD;
BEGIN
  -- Delete old clipboard items AND their storage files
  FOR v_to_delete IN
    SELECT id, storage_path
    FROM clipboard
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    OFFSET p_keep_count
  LOOP
    -- Delete storage file if it exists (images only)
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
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public';

COMMENT ON FUNCTION cleanup_old_clipboard_items(uuid, int) IS
'Cleans up old clipboard items for a specific user, keeping only the most recent N items.
Handles storage file deletion inline. Default keep count is 15.
SECURITY: search_path is set to public to prevent search path attacks.';
