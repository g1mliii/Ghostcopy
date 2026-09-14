-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:41:28 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Use HTTP extension instead of pg_net for calling edge function
CREATE OR REPLACE FUNCTION notify_mobile_devices_on_clipboard_insert()
RETURNS TRIGGER AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
  response_status integer;
  response_body text;
BEGIN
  -- Determine if this clipboard insert targets any mobile devices
  has_mobile_targets := (
    NEW.target_device_type IS NULL
    OR NEW.target_device_type @> ARRAY['ios'::device_type_enum]
    OR NEW.target_device_type @> ARRAY['android'::device_type_enum]
  );

  IF has_mobile_targets THEN
    -- Read encrypted secrets from Vault (automatically decrypted by vault.decrypted_secrets view)
    SELECT decrypted_secret INTO supabase_url 
      FROM vault.decrypted_secrets 
      WHERE name = 'supabase_api_url' LIMIT 1;
    
    SELECT decrypted_secret INTO service_role_key 
      FROM vault.decrypted_secrets 
      WHERE name = 'fcm_service_role_key' LIMIT 1;

    -- Use hardcoded fallback if vault secret not found
    supabase_url := COALESCE(supabase_url, 'https://xhbggxftvnlkotvehwmj.supabase.co');

    -- Only make the request if service role key is configured (not empty)
    IF service_role_key != '' AND service_role_key IS NOT NULL THEN
      -- Use http extension to POST to edge function
      -- Note: http extension is blocking but more reliable than pg_net
      SELECT status, content INTO response_status, response_body
      FROM http_post(
        uri := supabase_url || '/functions/v1/send-clipboard-notification',
        headers := jsonb_build_array(
          jsonb_build_object('key', 'Authorization', 'value', 'Bearer ' || service_role_key),
          jsonb_build_object('key', 'Content-Type', 'value', 'application/json')
        ),
        payload := jsonb_build_object(
          'record', row_to_json(NEW),
          'type', 'INSERT'
        )
      );

      IF response_status = 200 THEN
        RAISE LOG '[Clipboard Notify] Mobile target detected, edge function called successfully for clipboard_id=%', NEW.id;
      ELSE
        RAISE WARNING '[Clipboard Notify] Edge function returned status % for clipboard_id=%', response_status, NEW.id;
      END IF;
    ELSE
      RAISE WARNING '[Clipboard Notify] SERVICE_ROLE_KEY not configured in Vault. Add it via Supabase Vault UI or SQL.';
    END IF;
  ELSE
    RAISE LOG '[Clipboard Notify] Desktop-only targets (%), skipping edge function',
      COALESCE(array_to_string(NEW.target_device_type::text[], ', '), 'none');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
