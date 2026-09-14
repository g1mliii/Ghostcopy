-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 04:26:43 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Update notify_mobile_devices_on_clipboard_insert to read SERVICE_ROLE_KEY from app_config table
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
    -- Read secrets from app_config table
    SELECT value INTO supabase_url FROM app_config WHERE key = 'supabase_url' AND enabled = true LIMIT 1;
    SELECT value INTO service_role_key FROM app_config WHERE key = 'service_role_key' AND enabled = true LIMIT 1;

    -- Use hardcoded fallback if not found
    supabase_url := COALESCE(supabase_url, 'https://xhbggxftvnlkotvehwmj.supabase.co');

    -- Only make the request if service role key is configured
    IF service_role_key != '' AND service_role_key IS NOT NULL THEN
      PERFORM pg_net.http_post(
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
      RAISE WARNING '[Clipboard Notify] SERVICE_ROLE_KEY not configured in app_config, cannot invoke edge function. Add it via: UPDATE app_config SET value = ''your-key'' WHERE key = ''service_role_key''';
    END IF;
  ELSE
    RAISE LOG '[Clipboard Notify] Desktop-only targets (%), skipping edge function',
      COALESCE(array_to_string(NEW.target_device_type::text[], ', '), 'none');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path TO 'public';
