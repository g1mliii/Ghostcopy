-- Push for desktops: FCM (APNs) on macOS, WNS on Windows.
--
-- Until now only phones had push. A desktop learned of a new clip over a
-- realtime websocket it held open all day, one Supabase connection per
-- running desktop. Windows and macOS each keep a push connection of their own
-- for every app on the machine, so a desktop can be woken the way a phone is
-- and fetch the clip itself - the push never carries clipboard content.
--
-- Linux has no OS push service and stays on realtime.
--
-- Three changes, all inert until a desktop registers a token and the
-- desktop_push_enabled flag below is switched on:
--   1. devices.wns_channel_uri, the Windows equivalent of fcm_token. A macOS
--      desktop's FCM token goes in fcm_token, like a phone's.
--   2. The flag, off.
--   3. The insert trigger calls send-clipboard-notification whenever a
--      device it targets holds a push token - phone or desktop - and skips
--      the call when none does, which also saves the invocation for an
--      account with no phone at all.

-- 1. WNS channel URI ----------------------------------------------------------

ALTER TABLE public.devices
  ADD COLUMN IF NOT EXISTS wns_channel_uri text;

-- The edge function POSTs a bearer token to this URL, so only WNS hosts are
-- accepted here, and checked again before every send. A channel URI is an
-- https URL on *.notify.windows.com, well under 2 KB.
ALTER TABLE public.devices
  DROP CONSTRAINT IF EXISTS devices_wns_channel_uri_check;
ALTER TABLE public.devices
  ADD CONSTRAINT devices_wns_channel_uri_check CHECK (
    wns_channel_uri IS NULL OR (
      length(wns_channel_uri) <= 2048
      AND wns_channel_uri ~ '^https://[a-z0-9.-]+\.notify\.windows\.com/'
    )
  );

COMMENT ON COLUMN public.devices.wns_channel_uri IS
  'WNS channel URI for a packaged Windows desktop. Expires after 30 days; the app requests a fresh one on every launch. NULL when the desktop uses realtime only.';

-- 2. Rollout flag -------------------------------------------------------------

INSERT INTO public.app_config (key, enabled)
VALUES ('desktop_push_enabled', false)
ON CONFLICT (key) DO NOTHING;

-- 3. Trigger ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.notify_mobile_devices_on_clipboard_insert()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
DECLARE
  has_push_target boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  -- Any device the clip is for, other than the sending type, that push can
  -- reach. The edge function applies the same rules when it picks devices.
  SELECT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.user_id = NEW.user_id
      AND d.device_type <> NEW.device_type
      AND (
        NEW.target_device_type IS NULL
        OR cardinality(NEW.target_device_type) = 0
        OR d.device_type = ANY (NEW.target_device_type)
      )
      AND (d.fcm_token IS NOT NULL OR d.wns_channel_uri IS NOT NULL)
  ) INTO has_push_target;

  IF NOT has_push_target THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT decrypted_secret
    INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_api_url'
    LIMIT 1;

    SELECT decrypted_secret
    INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'fcm_service_role_key'
    LIMIT 1;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Clipboard Notify] Unable to access Vault secrets: %', SQLERRM;
  END;

  IF COALESCE(supabase_url, '') = '' THEN
    supabase_url := NULLIF(current_setting('app.settings.supabase_url', true), '');
  END IF;

  IF COALESCE(service_role_key, '') = '' THEN
    service_role_key := NULLIF(current_setting('app.settings.service_role_key', true), '');
  END IF;

  IF COALESCE(supabase_url, '') = '' OR COALESCE(service_role_key, '') = '' THEN
    RAISE WARNING '[Clipboard Notify] Missing Supabase URL or service role key for clipboard_id=%', NEW.id;
    RETURN NEW;
  END IF;

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

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notify_mobile_devices_on_clipboard_insert() IS
  'Calls send-clipboard-notification when a device the clip targets (other than the sending type) holds a push token: FCM for phones and macOS, WNS for Windows. Skips the call otherwise.';
