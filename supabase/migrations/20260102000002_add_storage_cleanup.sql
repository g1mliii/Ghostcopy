-- Migration: Add automatic storage cleanup on clipboard item deletion
-- Date: 2026-01-02
-- Description: Trigger to auto-delete storage files when clipboard items are deleted

-- Function to delete storage file when clipboard item is deleted
CREATE OR REPLACE FUNCTION delete_clipboard_storage_file()
RETURNS TRIGGER AS $$
BEGIN
  -- Only delete from storage if storage_path exists (images only)
  IF OLD.storage_path IS NOT NULL THEN
    PERFORM storage.delete_object('clipboard-files', OLD.storage_path);
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to auto-delete storage files before clipboard record deletion
CREATE TRIGGER trigger_delete_clipboard_storage_file
BEFORE DELETE ON clipboard
FOR EACH ROW
EXECUTE FUNCTION delete_clipboard_storage_file();

-- Update cleanup function to handle storage files
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items(
  p_user_id uuid,
  p_keep_count int DEFAULT 15  -- Updated from 10 to 15
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
    -- Trigger will handle storage file deletion
    DELETE FROM clipboard WHERE id = v_to_delete.id;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION delete_clipboard_storage_file() IS 'Automatically deletes storage files when clipboard items are deleted';
COMMENT ON FUNCTION cleanup_old_clipboard_items(uuid, int) IS 'Cleans up old clipboard items, keeping only the most recent N items. Default keep count is 15.';
