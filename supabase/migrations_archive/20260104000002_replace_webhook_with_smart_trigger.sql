-- Replace webhook with smart database trigger for cost optimization
-- Date: 2026-01-04
-- Description: Only call edge function if mobile devices are targeted
-- Impact: Eliminates wasted invocations for desktop-only sends (~20-30% savings)

/*
SETUP INSTRUCTIONS:

1. Set environment variables in Supabase Project Settings:
   - Go to Project Settings → Functions → Environment Variables
   - Add: SUPABASE_URL = https://xxxxx.supabase.co
   - Add: SERVICE_ROLE_KEY = your-service-role-key (from Project Settings → API)

2. Ensure pg_net extension is enabled:
   - This is typically enabled by default in Supabase
   - If not, run: CREATE EXTENSION IF NOT EXISTS pg_net;

3. After migration runs, the trigger will automatically:
   - Fire on every clipboard INSERT
   - Check if target_device_type includes mobile devices
   - Only call edge function for mobile-targeted clips
   - Skip edge function for desktop-only clips (saves invocations)

COST SAVINGS:
- Desktop-only sends: 0 invocations (was 1)
- Mobile-targeted sends: 1 invocation (unchanged)
- Broadcast sends: 1 invocation (unchanged)

Example: If 30% of sends are desktop-only:
  Before: 1,000 invocations/month
  After: 700 invocations/month (300 saved)
*/

-- Drop old webhook trigger (if you had one)
-- Note: Webhooks are configured in UI, but we're replacing with database trigger

-- Create function to check if record targets mobile devices and call edge function if needed
CREATE OR REPLACE FUNCTION notify_mobile_devices_on_clipboard_insert()
RETURNS TRIGGER AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  -- Determine if this clipboard insert targets any mobile devices
  -- target_device_type can be:
  --   NULL = broadcast to all (assume mobile devices may exist)
  --   ['android'] = explicit mobile
  --   ['ios'] = explicit mobile
  --   ['android', 'ios'] = explicit mobile
  --   ['windows', 'macos'] = desktop only (skip edge function)
  --   ['windows', 'macos', 'android'] = mixed (includes mobile)

  -- Check if target_device_type is null or contains mobile device types
  has_mobile_targets := (
    NEW.target_device_type IS NULL  -- null = broadcast to all devices
    OR NEW.target_device_type @> ARRAY['ios']::text[]  -- contains 'ios'
    OR NEW.target_device_type @> ARRAY['android']::text[]  -- contains 'android'
  );

  -- Only invoke edge function if mobile devices might receive this
  IF has_mobile_targets THEN
    -- Use pg_net to make HTTP POST to edge function
    -- pg_net is async by default (doesn't block INSERT)
    -- Note: You must set these environment variables in Supabase Project Settings:
    --   SUPABASE_URL: https://xxxxx.supabase.co
    --   SERVICE_ROLE_KEY: your-service-role-key

    supabase_url := COALESCE(current_setting('app.settings.supabase_url', true),
                              'https://[YOUR-PROJECT].supabase.co');
    service_role_key := COALESCE(current_setting('app.settings.service_role_key', true),
                                 '');

    -- Only make the request if service role key is configured
    IF service_role_key != '' THEN
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
      RAISE WARNING '[Clipboard Notify] SERVICE_ROLE_KEY not configured, cannot invoke edge function';
    END IF;
  ELSE
    -- Desktop-only targets, skip edge function (saves cost)
    RAISE LOG '[Clipboard Notify] Desktop-only targets (%), skipping edge function',
      COALESCE(array_to_string(NEW.target_device_type, ', '), 'none');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SET search_path TO 'public';

-- Create trigger that fires AFTER INSERT on clipboard
-- AFTER (not BEFORE) so we have the generated ID
DROP TRIGGER IF EXISTS clipboard_notify_mobile_on_insert ON clipboard;

CREATE TRIGGER clipboard_notify_mobile_on_insert
AFTER INSERT ON clipboard
FOR EACH ROW
EXECUTE FUNCTION notify_mobile_devices_on_clipboard_insert();

COMMENT ON FUNCTION notify_mobile_devices_on_clipboard_insert() IS
'Smart trigger that only calls FCM edge function if mobile devices are targeted.
Desktop-only sends skip the edge function call entirely, saving invocation costs.
Uses pg_net for async HTTP POST (non-blocking).';

COMMENT ON TRIGGER clipboard_notify_mobile_on_insert ON clipboard IS
'Triggers send-clipboard-notification edge function only for mobile-targeted clips.
Filters desktop-only sends at DB level to optimize costs (0 invocations).
Fires AFTER INSERT so clipboard_id is generated.';
