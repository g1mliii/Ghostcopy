-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:40:49 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix trigger to use correct pg_net schema (extensions.pg_net)
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
      PERFORM extensions.pg_net.http_post(
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

      RAISE LOG '[Clipboard Notify] Mobile target detected, invoking edge function for clipboard_id=%', NEW.id;
    ELSE
      RAISE WARNING '[Clipboard Notify] SERVICE_ROLE_KEY not configured in Vault. Add it via Supabase Vault UI or SQL.';
    END IF;
  ELSE
    RAISE LOG '[Clipboard Notify] Desktop-only targets (%), skipping edge function',
      COALESCE(array_to_string(NEW.target_device_type::text[], ', '), 'none');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path TO 'public', 'extensions';
