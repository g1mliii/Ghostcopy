-- Migration: Update storage cleanup trigger to use R2 via edge function
-- Date: 2026-02-21
-- Description: Replaces direct Supabase Storage deletion with a call to
--              the storage-presign edge function which deletes from R2.
--
-- CHANGE:
--   Old: pg_net.http_delete(supabase_url/storage/v1/object/clipboard-files/path)
--   New: pg_net.http_post(supabase_url/functions/v1/storage-presign, {action:'delete', path})
--
-- The edge function authenticates via service-role key and deletes from R2.

-- Ensure pg_net extension is enabled
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Replace the cleanup function to call storage-presign edge function
CREATE OR REPLACE FUNCTION cleanup_storage_on_clipboard_delete()
RETURNS TRIGGER AS $$
DECLARE
  supabase_url text;
  service_role_key text;
  full_url text;
  request_body jsonb;
BEGIN
  -- Only process if item had a storage path (i.e., was an image/file)
  IF OLD.storage_path IS NULL THEN
    RETURN OLD;
  END IF;

  -- Get secrets from Supabase Vault
  BEGIN
    SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_api_url'
    LIMIT 1;

    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'fcm_service_role_key'
    LIMIT 1;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Storage Cleanup R2] Unable to access Supabase Vault secrets: %', SQLERRM;
      RETURN OLD;
  END;

  -- Validate secrets
  IF supabase_url IS NULL OR service_role_key IS NULL OR
     supabase_url = '' OR service_role_key = '' THEN
    RAISE WARNING '[Storage Cleanup R2] Vault secrets not configured. Cannot delete R2 file: %',
      OLD.storage_path;
    RETURN OLD;
  END IF;

  -- Call storage-presign edge function with delete action
  full_url := supabase_url || '/functions/v1/storage-presign';
  request_body := jsonb_build_object(
    'action', 'delete',
    'path', OLD.storage_path
  );

  BEGIN
    PERFORM pg_net.http_post(
      url := full_url,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_role_key,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 5000
    );

    RAISE LOG '[Storage Cleanup R2] Deleted file from R2: % (clipboard_id: %)',
      OLD.storage_path,
      OLD.id;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Storage Cleanup R2] Failed to delete R2 file % for clipboard_id %: %',
        OLD.storage_path,
        OLD.id,
        SQLERRM;
  END;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault';

-- Recreate trigger (drop + create ensures clean state)
DROP TRIGGER IF EXISTS cleanup_storage_after_clipboard_delete ON clipboard;

CREATE TRIGGER cleanup_storage_after_clipboard_delete
  AFTER DELETE ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_storage_on_clipboard_delete();

COMMENT ON FUNCTION cleanup_storage_on_clipboard_delete() IS
'Auto-deletes files from Cloudflare R2 when clipboard items are deleted.
Calls storage-presign edge function with delete action via pg_net.
Securely retrieves service role key from Supabase Vault.';

COMMENT ON TRIGGER cleanup_storage_after_clipboard_delete ON clipboard IS
'Automatically cleans up R2 storage files when clipboard items are deleted.
Non-blocking via pg_net async HTTP. Uses Supabase Vault for secrets.';
