-- Make fcm_token nullable in devices table
-- Desktop devices don't use FCM (they use Supabase Realtime instead)
-- Only mobile devices (Android/iOS) need FCM tokens for push notifications

-- Step 1: Drop the NOT NULL constraint on fcm_token
ALTER TABLE devices ALTER COLUMN fcm_token DROP NOT NULL;

-- Step 2: Drop the existing check constraint (length validation)
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_fcm_token_check;

-- Step 3: Add new check constraint that allows NULL or validates length
ALTER TABLE devices ADD CONSTRAINT devices_fcm_token_check
  CHECK (fcm_token IS NULL OR (length(fcm_token) > 0 AND length(fcm_token) <= 4096));

-- Step 4: Update comment to reflect nullable state
COMMENT ON COLUMN devices.fcm_token IS 'FCM token for push notifications. NULL for desktop devices (use Realtime), required for mobile (Android/iOS)';

-- Step 5: Create unique index to prevent duplicate device registrations
-- A device is uniquely identified by: user_id + device_type + device_name
-- This allows multiple devices of same type if they have different names
CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_user_type_name
  ON devices(user_id, device_type, COALESCE(device_name, ''));

-- Step 6: Add index for querying active devices (for cleanup)
CREATE INDEX IF NOT EXISTS idx_devices_last_active
  ON devices(last_active DESC);

-- Step 7: Add index for FCM token lookups (for Edge Function)
CREATE INDEX IF NOT EXISTS idx_devices_fcm_token
  ON devices(user_id, device_type)
  WHERE fcm_token IS NOT NULL;
