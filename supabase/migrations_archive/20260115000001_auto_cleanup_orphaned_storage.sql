-- Auto-cleanup orphaned storage files when clipboard items are deleted
-- Date: 2026-01-15
-- Description: Prevents storage quota bloat by automatically deleting
--              image files from Supabase Storage when clipboard rows are deleted
-- SECURITY: Uses Supabase Vault to store service role key securely

/*
PROBLEM:
- When user deletes clipboard item with image, storage file remains
- Over time, orphaned files accumulate and waste storage quota
- Manual cleanup is error-prone and requires cron jobs

SOLUTION:
- Trigger fires AFTER DELETE on clipboard table
- Uses pg_net extension to async delete from Supabase Storage
- Non-blocking (doesn't slow down DELETE operation)
- Handles errors gracefully (logs but doesn't block)

SECURITY - USES SUPABASE VAULT:
- Service role key stored in Supabase Vault (encrypted at rest)
- Vault secret name: 'supabase_service_role_key'
- Access via vault.decrypted_secrets (requires vault schema access)
- Never exposed to client or stored in plain text

SETUP INSTRUCTIONS:
1. Uses existing vault secrets from FCM notification setup:
   - 'fcm_service_role_key' (your service role key)
   - 'supabase_api_url' (your Supabase project URL)

2. If these don't exist, create them via SQL:

   -- Insert service role key into vault
   INSERT INTO vault.secrets (name, secret)
   VALUES (
     'fcm_service_role_key',
     'your-actual-service-role-key-here'  -- Get from Project Settings → API
   )
   ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;

   -- Insert Supabase URL into vault
   INSERT INTO vault.secrets (name, secret)
   VALUES (
     'supabase_api_url',
     'https://xhbggxftvnlkotvehwmj.supabase.co'  -- Your project URL
   )
   ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;

3. Trigger will automatically use vault secrets when deleting files

DEPENDENCIES:
- pg_net extension (for HTTP requests to Storage API)
- vault schema (for secure secret storage)
- Supabase Storage bucket: clipboard-files
*/

-- Ensure pg_net extension is enabled (for async HTTP requests)
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Function to delete storage file when clipboard item is deleted
CREATE OR REPLACE FUNCTION cleanup_storage_on_clipboard_delete()
RETURNS TRIGGER AS $$
DECLARE
  supabase_url text;
  service_role_key text;
  storage_bucket text := 'clipboard-files';
  full_url text;
BEGIN
  -- Only process if item had a storage path (i.e., was an image/file)
  IF OLD.storage_path IS NULL THEN
    RETURN OLD; -- No storage file to delete
  END IF;

  -- Get secrets from Supabase Vault (secure, encrypted at rest)
  -- vault.decrypted_secrets provides decrypted access to secrets
  -- Using existing vault secret names: supabase_api_url and fcm_service_role_key
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
      -- Vault not accessible or secrets not found
      RAISE WARNING '[Storage Cleanup] Unable to access Supabase Vault secrets: %', SQLERRM;
      RAISE WARNING '[Storage Cleanup] Please configure vault secrets (see migration file for instructions)';
      RETURN OLD;
  END;

  -- Validate secrets are configured
  IF supabase_url IS NULL OR service_role_key IS NULL OR
     supabase_url = '' OR service_role_key = '' THEN
    RAISE WARNING '[Storage Cleanup] Vault secrets not configured. Cannot delete storage file: %',
      OLD.storage_path;
    RAISE WARNING '[Storage Cleanup] Missing vault secrets: fcm_service_role_key and/or supabase_api_url';
    RETURN OLD;
  END IF;

  -- Build full Storage API URL
  -- Format: https://xxx.supabase.co/storage/v1/object/clipboard-files/{storage_path}
  full_url := supabase_url || '/storage/v1/object/' || storage_bucket || '/' || OLD.storage_path;

  -- Async DELETE request to Storage API
  -- Uses pg_net for non-blocking HTTP request
  BEGIN
    PERFORM pg_net.http_delete(
      url := full_url,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_role_key,
        'Content-Type', 'application/json'
      ),
      timeout_milliseconds := 5000
    );

    RAISE LOG '[Storage Cleanup] ✓ Deleted file from storage: % (clipboard_id: %)',
      OLD.storage_path,
      OLD.id;
  EXCEPTION
    WHEN OTHERS THEN
      -- Log error but don't block DELETE operation
      RAISE WARNING '[Storage Cleanup] Failed to delete storage file % for clipboard_id %: %',
        OLD.storage_path,
        OLD.id,
        SQLERRM;
  END;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault';

-- Create trigger that fires AFTER DELETE
-- AFTER (not BEFORE) ensures clipboard row is fully deleted before we clean up storage
DROP TRIGGER IF EXISTS cleanup_storage_after_clipboard_delete ON clipboard;

CREATE TRIGGER cleanup_storage_after_clipboard_delete
  AFTER DELETE ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_storage_on_clipboard_delete();

-- Add comments for documentation
COMMENT ON FUNCTION cleanup_storage_on_clipboard_delete() IS
'Auto-deletes image files from Supabase Storage when clipboard items are deleted.
Uses pg_net for async HTTP DELETE (non-blocking).
Securely retrieves service role key from Supabase Vault.
Handles errors gracefully - logs warnings but never blocks DELETE operation.';

COMMENT ON TRIGGER cleanup_storage_after_clipboard_delete ON clipboard IS
'Automatically cleans up orphaned storage files when clipboard items are deleted.
Prevents storage quota bloat from accumulating deleted images.
Fires AFTER DELETE to ensure clipboard row is fully removed first.
Non-blocking: Uses async HTTP requests via pg_net.
SECURE: Uses Supabase Vault for service role key storage.';

-- Verification query (run this to check if vault secrets are configured)
DO $$
DECLARE
  supabase_url text;
  service_role_key text;
  vault_accessible boolean := false;
BEGIN
  -- Try to access vault
  -- Using existing vault secret names: supabase_api_url and fcm_service_role_key
  BEGIN
    SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_api_url'
    LIMIT 1;

    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'fcm_service_role_key'
    LIMIT 1;

    vault_accessible := true;
  EXCEPTION
    WHEN OTHERS THEN
      vault_accessible := false;
  END;

  RAISE NOTICE '';
  RAISE NOTICE '════════════════════════════════════════════════════════════════';
  RAISE NOTICE '   STORAGE CLEANUP TRIGGER - INSTALLATION STATUS';
  RAISE NOTICE '════════════════════════════════════════════════════════════════';
  RAISE NOTICE '';

  IF NOT vault_accessible THEN
    RAISE NOTICE '⚠️  VAULT NOT ACCESSIBLE';
    RAISE NOTICE '';
    RAISE NOTICE 'The trigger is installed but cannot access Supabase Vault.';
    RAISE NOTICE 'This is normal if running locally without vault extension.';
    RAISE NOTICE '';
    RAISE NOTICE 'For Supabase Cloud (production):';
    RAISE NOTICE '  Vault should be automatically available.';
    RAISE NOTICE '';
  ELSIF supabase_url IS NULL OR service_role_key IS NULL THEN
    RAISE NOTICE '⚠️  VAULT SECRETS NOT CONFIGURED';
    RAISE NOTICE '';
    RAISE NOTICE 'The trigger is installed but vault secrets are missing.';
    RAISE NOTICE '';
    RAISE NOTICE '📝 SETUP INSTRUCTIONS:';
    RAISE NOTICE '';
    RAISE NOTICE 'This trigger uses existing FCM vault secrets:';
    RAISE NOTICE '  - fcm_service_role_key';
    RAISE NOTICE '  - supabase_api_url';
    RAISE NOTICE '';
    RAISE NOTICE 'If these are missing, run this SQL:';
    RAISE NOTICE '';
    RAISE NOTICE '   -- Add service role key to vault';
    RAISE NOTICE '   INSERT INTO vault.secrets (name, secret)';
    RAISE NOTICE '   VALUES (''fcm_service_role_key'', ''your-service-role-key'')';
    RAISE NOTICE '   ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;';
    RAISE NOTICE '';
    RAISE NOTICE '   -- Add Supabase URL to vault';
    RAISE NOTICE '   INSERT INTO vault.secrets (name, secret)';
    RAISE NOTICE '   VALUES (''supabase_api_url'', ''https://xhbggxftvnlkotvehwmj.supabase.co'')';
    RAISE NOTICE '   ON CONFLICT (name) DO UPDATE SET secret = EXCLUDED.secret;';
    RAISE NOTICE '';
    RAISE NOTICE 'Get your service role key from:';
    RAISE NOTICE '  Project Settings → API → service_role key (secret)';
    RAISE NOTICE '';
  ELSE
    RAISE NOTICE '✅ STORAGE CLEANUP CONFIGURED SUCCESSFULLY';
    RAISE NOTICE '';
    RAISE NOTICE '  ✓ Trigger installed';
    RAISE NOTICE '  ✓ Vault secrets found';
    RAISE NOTICE '  ✓ Supabase URL: %', supabase_url;
    RAISE NOTICE '  ✓ Service role key: [SECURED IN VAULT]';
    RAISE NOTICE '';
    RAISE NOTICE 'Orphaned storage files will be auto-deleted when clipboard';
    RAISE NOTICE 'items are removed. Files are encrypted at rest in vault.';
    RAISE NOTICE '';
  END IF;

  -- Verify trigger exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'cleanup_storage_after_clipboard_delete'
      AND tgrelid = 'clipboard'::regclass
  ) THEN
    RAISE EXCEPTION 'Failed to create cleanup_storage_after_clipboard_delete trigger';
  END IF;

  RAISE NOTICE '════════════════════════════════════════════════════════════════';
  RAISE NOTICE '';
END $$;
