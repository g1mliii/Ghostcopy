-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:43:30 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix: Use pg_net without schema qualification, rely on search_path instead
CREATE OR REPLACE FUNCTION notify_mobile_devices_on_clipboard_insert()
RETURNS TRIGGER AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  -- Determine if this clipboard insert targets any mobile devices
  has_mobile_targets := (
    NEW.target_device_type IS NULL
    OR NEW.target_device_type @> ARRAY['ios'::device_type_enum]
    OR NEW.target_device_type @> ARRAY['android'::device_type_enum]
  );

  IF has_mobile_targets THEN
    -- Read encrypted secrets from Vault
    SELECT decrypted_secret INTO supabase_url 
      FROM vault.decrypted_secrets 
      WHERE name = 'supabase_api_url' LIMIT 1;
    
    SELECT decrypted_secret INTO service_role_key 
      FROM vault.decrypted_secrets 
      WHERE name = 'fcm_service_role_key' LIMIT 1;

    supabase_url := COALESCE(supabase_url, 'https://xhbggxftvnlkotvehwmj.supabase.co');

    -- Only call if service_role_key is configured
    IF service_role_key IS NOT NULL AND service_role_key != '' THEN
      -- Call pg_net WITHOUT schema qualification (search_path handles it)
      PERFORM pg_net.http_post(
        supabase_url || '/functions/v1/send-clipboard-notification',
        jsonb_build_object(
          'record', row_to_json(NEW),
          'type', 'INSERT'
        ),
        'Bearer ' || service_role_key
      );

      RAISE LOG '[Clipboard Notify] Mobile target detected, edge function invoked for clipboard_id=%', NEW.id;
    ELSE
      RAISE WARNING '[Clipboard Notify] SERVICE_ROLE_KEY not configured in Vault';
    END IF;
  ELSE
    RAISE LOG '[Clipboard Notify] Desktop-only targets (%), skipping edge function',
      COALESCE(array_to_string(NEW.target_device_type::text[], ', '), 'none');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SET search_path = 'extensions', 'public';
