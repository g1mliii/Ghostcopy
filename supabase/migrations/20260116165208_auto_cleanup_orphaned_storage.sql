-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-16 16:52:08 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Auto-cleanup orphaned storage files when clipboard items are deleted
-- Date: 2026-01-15
-- SECURITY: Uses Supabase Vault with existing FCM secrets

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

  -- Get secrets from Supabase Vault (uses existing FCM secrets)
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
      RAISE WARNING '[Storage Cleanup] Unable to access Supabase Vault secrets: %', SQLERRM;
      RAISE WARNING '[Storage Cleanup] Please configure vault secrets';
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
  full_url := supabase_url || '/storage/v1/object/' || storage_bucket || '/' || OLD.storage_path;

  -- Async DELETE request to Storage API
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
DROP TRIGGER IF EXISTS cleanup_storage_after_clipboard_delete ON clipboard;

CREATE TRIGGER cleanup_storage_after_clipboard_delete
  AFTER DELETE ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_storage_on_clipboard_delete();

-- Add comments
COMMENT ON FUNCTION cleanup_storage_on_clipboard_delete() IS
'Auto-deletes image files from Supabase Storage when clipboard items are deleted.
Uses pg_net for async HTTP DELETE. Securely retrieves secrets from Vault.';

COMMENT ON TRIGGER cleanup_storage_after_clipboard_delete ON clipboard IS
'Cleans up orphaned storage files. Uses Vault secrets: fcm_service_role_key, supabase_api_url.';

-- Verify and show status
DO $$
DECLARE
  supabase_url text;
  service_role_key text;
  vault_accessible boolean := false;
BEGIN
  -- Try to access vault
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
    RAISE NOTICE 'Trigger installed but vault not available (normal for local dev)';
  ELSIF supabase_url IS NULL OR service_role_key IS NULL THEN
    RAISE NOTICE '⚠️  VAULT SECRETS NOT CONFIGURED';
    RAISE NOTICE 'Missing: fcm_service_role_key and/or supabase_api_url';
  ELSE
    RAISE NOTICE '✅ STORAGE CLEANUP CONFIGURED SUCCESSFULLY';
    RAISE NOTICE '';
    RAISE NOTICE '  ✓ Trigger installed';
    RAISE NOTICE '  ✓ Vault secrets found (fcm_service_role_key, supabase_api_url)';
    RAISE NOTICE '  ✓ Supabase URL: %', supabase_url;
    RAISE NOTICE '  ✓ Service role key: [SECURED IN VAULT]';
    RAISE NOTICE '';
    RAISE NOTICE 'Orphaned storage files will auto-delete when clipboard items removed.';
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
