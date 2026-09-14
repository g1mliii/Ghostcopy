-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:43:01 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Simplify trigger to use basic pg_net syntax
CREATE OR REPLACE FUNCTION notify_mobile_devices_on_clipboard_insert()
RETURNS TRIGGER AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
  request_body jsonb;
  request_headers jsonb;
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
      -- Prepare the request body and headers
      request_body := jsonb_build_object(
        'record', row_to_json(NEW),
        'type', 'INSERT'
      );
      
      request_headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_role_key,
        'Content-Type', 'application/json'
      );

      -- Call edge function via pg_net (async, non-blocking)
      PERFORM extensions.pg_net.http_post(
        url := supabase_url || '/functions/v1/send-clipboard-notification',
        body := request_body,
        headers := request_headers,
        timeout_milliseconds := 30000
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
$$ LANGUAGE plpgsql;
