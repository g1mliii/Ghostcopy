-- Migration: Fix R2 cleanup trigger reliability
-- Date: 2026-02-22
-- Root cause: function used pg_net.http_post but correct schema is net.http_post
-- Also adds apikey header required by Supabase edge function gateway

CREATE OR REPLACE FUNCTION cleanup_storage_on_clipboard_delete()
RETURNS TRIGGER AS $$
DECLARE
  supabase_url text;
  service_role_key text;
  full_url text;
  request_body jsonb;
BEGIN
  IF OLD.storage_path IS NULL THEN
    RETURN OLD;
  END IF;

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
      RAISE WARNING '[Storage Cleanup R2] Unable to access Vault secrets: %', SQLERRM;
      RETURN OLD;
  END;

  IF COALESCE(supabase_url, '') = '' OR COALESCE(service_role_key, '') = '' THEN
    RAISE WARNING '[Storage Cleanup R2] Missing vault secrets. path=%', OLD.storage_path;
    RETURN OLD;
  END IF;

  full_url := supabase_url || '/functions/v1/storage-presign';
  request_body := jsonb_build_object(
    'action', 'delete',
    'path', OLD.storage_path
  );

  BEGIN
    PERFORM net.http_post(
      url := full_url,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_role_key,
        'apikey', service_role_key,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 5000
    );

    RAISE LOG '[Storage Cleanup R2] Delete requested for % (clipboard_id: %)',
      OLD.storage_path, OLD.id;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Storage Cleanup R2] Failed to delete % (clipboard_id %): %',
        OLD.storage_path, OLD.id, SQLERRM;
  END;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault';

ALTER FUNCTION cleanup_storage_on_clipboard_delete() OWNER TO postgres;

DROP TRIGGER IF EXISTS cleanup_storage_after_clipboard_delete ON clipboard;

CREATE TRIGGER cleanup_storage_after_clipboard_delete
  AFTER DELETE ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION cleanup_storage_on_clipboard_delete();
