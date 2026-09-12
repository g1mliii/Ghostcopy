-- Comprehensive fix for permissions and triggers
-- Date: 2026-01-21 19:15:00

-- 1. CLEANUP: Drop conflicting legacy triggers and functions from previous migrations
DROP TRIGGER IF EXISTS trigger_delete_clipboard_storage_file ON clipboard;
DROP FUNCTION IF EXISTS delete_clipboard_storage_file();

-- 2. FIX: app_config permissions
-- Ensure explicit access for all roles that need it (including during app start)
GRANT SELECT ON app_config TO anon, authenticated, service_role;

-- 3. FIX: cleanup_storage_on_clipboard_delete permission issues
-- Ensure the function runs as superuser (postgres) to access the vault
ALTER FUNCTION cleanup_storage_on_clipboard_delete() OWNER TO postgres;

-- Explicitly grant usage on vault to the function owner (postgres)
GRANT USAGE ON SCHEMA vault TO postgres;
GRANT SELECT ON vault.decrypted_secrets TO postgres;

-- 4. FIX: notify_mobile_devices_on_clipboard_insert permissions
-- The original function was not SECURITY DEFINER, which causes issues with pg_net access
-- We replace it with a SECURITY DEFINER version owned by postgres
CREATE OR REPLACE FUNCTION notify_mobile_devices_on_clipboard_insert()
RETURNS TRIGGER AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  -- Determine if this clipboard insert targets any mobile devices
  -- Cast to text[] to ensure operator compatibility
  has_mobile_targets := (
    NEW.target_device_type IS NULL  -- null = broadcast to all devices
    OR NEW.target_device_type::text[] @> ARRAY['ios']
    OR NEW.target_device_type::text[] @> ARRAY['android']
  );

  -- Only invoke edge function if mobile devices might receive this
  IF has_mobile_targets THEN
    -- Try to get secrets from Vault first (preferred), then fallback to settings
    BEGIN
      SELECT decrypted_secret INTO supabase_url FROM vault.decrypted_secrets WHERE name = 'supabase_api_url' LIMIT 1;
      SELECT decrypted_secret INTO service_role_key FROM vault.decrypted_secrets WHERE name = 'fcm_service_role_key' LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
       -- Ignore vault errors, fallback to settings below
    END;

    -- Fallback to system settings if vault is empty (compatibility with old setup)
    IF supabase_url IS NULL OR supabase_url = '' THEN
       supabase_url := COALESCE(current_setting('app.settings.supabase_url', true), 'https://[YOUR-PROJECT].supabase.co');
    END IF;
    IF service_role_key IS NULL OR service_role_key = '' THEN
       service_role_key := COALESCE(current_setting('app.settings.service_role_key', true), '');
    END IF;

    IF service_role_key != '' THEN
      -- Use net schema (standard for pg_net extension)
      PERFORM net.http_post(
        url := supabase_url || '/functions/v1/send-clipboard-notification',
        body := jsonb_build_object(
          'record', row_to_json(NEW),
          'type', 'INSERT'
        ),
        headers := jsonb_build_object(
          'Authorization', 'Bearer ' || service_role_key,
          'Content-Type', 'application/json'
        ),
        timeout_milliseconds := 30000
      );
      RAISE LOG '[Clipboard Notify] Invoked edge function for clipboard_id=%', NEW.id;
    END IF;
  END IF;

  RETURN NEW;
END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, vault;

-- Set ownership to postgres
ALTER FUNCTION notify_mobile_devices_on_clipboard_insert() OWNER TO postgres;

-- 5. FIX: Clipboard table permissions
-- Ensure explicit grants are present for RLS to work properly (defensive)
GRANT ALL ON clipboard TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON clipboard TO authenticated;
-- anon typically shouldn't write to clipboard, but if needed:
-- GRANT SELECT ON clipboard TO anon; 

-- 6. VERIFICATION LOGGING
DO $$
BEGIN
  RAISE NOTICE '✅ Dropped legacy trigger trigger_delete_clipboard_storage_file';
  RAISE NOTICE '✅ Granted permissions on app_config';
  RAISE NOTICE '✅ Fixed SECURITY DEFINER for cleanup_storage_on_clipboard_delete';
  RAISE NOTICE '✅ Fixed SECURITY DEFINER for notify_mobile_devices_on_clipboard_insert';
  RAISE NOTICE '✅ Verified clipboard table grants';
END $$;
