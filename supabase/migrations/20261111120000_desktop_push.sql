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

-- A channel URI addresses one install. When that install signs into another
-- account, the old account's row would keep it and go on waking this desktop
-- for someone else's clips; RLS stops the app clearing another account's row,
-- so the claim happens here, the way claim_fcm_token does it for FCM.
CREATE OR REPLACE FUNCTION public.claim_wns_channel(p_device_id uuid, p_uri text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Not signed in';
  END IF;
  IF p_uri IS NULL
     OR length(p_uri) > 2048
     OR p_uri !~ '^https://[a-z0-9.-]+\.notify\.windows\.com/' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Not a WNS channel URI';
  END IF;

  PERFORM 1 FROM public.devices
  WHERE id = p_device_id AND user_id = auth.uid()
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE public.devices SET wns_channel_uri = NULL
  WHERE wns_channel_uri = p_uri AND id <> p_device_id;

  UPDATE public.devices SET wns_channel_uri = p_uri, last_active = now()
  WHERE id = p_device_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_wns_channel(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_wns_channel(uuid, text) TO authenticated;

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
  desktop_push boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  -- Desktops count only while the flag is on: turning it off must stop
  -- pushes to desktops that registered while it was on.
  SELECT COALESCE(
    (SELECT enabled FROM public.app_config WHERE key = 'desktop_push_enabled'),
    false
  ) INTO desktop_push;

  -- Other desktops of the sender's platform must still receive. Desktop
  -- sync identifies the sender by device_name (clipboard has no device id).
  -- Preserve the existing same-platform exclusion for phones.
  -- The edge function applies the same rules when it picks devices.
  SELECT EXISTS (
    SELECT 1
    FROM public.devices d
    WHERE d.user_id = NEW.user_id
      AND (
        d.device_type <> NEW.device_type
        OR (
          d.device_type IN ('windows', 'macos', 'linux')
          AND d.device_name IS DISTINCT FROM NEW.device_name
        )
      )
      AND (
        NEW.target_device_type IS NULL
        OR cardinality(NEW.target_device_type) = 0
        OR d.device_type = ANY (NEW.target_device_type)
      )
      AND (d.fcm_token IS NOT NULL OR d.wns_channel_uri IS NOT NULL)
      AND (desktop_push OR d.device_type IN ('ios', 'android'))
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
    -- Only what the function reads. The whole row carried the clip itself
    -- (up to 100 KB of content) through pg_net for every insert, and no push
    -- may carry clipboard content anyway.
    body := jsonb_build_object(
      'record', jsonb_build_object(
        'id', NEW.id,
        'user_id', NEW.user_id,
        'device_type', NEW.device_type,
        'device_name', NEW.device_name,
        'target_device_type', NEW.target_device_type,
        'content_type', NEW.content_type,
        'file_size_bytes', NEW.file_size_bytes,
        'rich_text_format', NEW.rich_text_format
      ),
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
  'Calls send-clipboard-notification when another targeted device holds a push token: FCM for phones and macOS, WNS for Windows. Same-platform desktops are distinguished by device_name; phones retain same-platform exclusion.';
