-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-16 17:01:46 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add rate limiting to devices table
-- Date: 2026-01-15
-- Description: Prevents users from registering excessive devices (spam protection)
-- Limit: Maximum 10 devices per user (generous for multi-device users)

-- Function to check device count before insert
CREATE OR REPLACE FUNCTION check_devices_rate_limit()
RETURNS TRIGGER AS $$
DECLARE
  device_count int;
  max_devices int := 10; -- Allow up to 10 devices per user
BEGIN
  -- Count existing devices for this user
  SELECT COUNT(*) INTO device_count
  FROM devices
  WHERE user_id = NEW.user_id;

  -- Check if user has reached the limit
  IF device_count >= max_devices THEN
    RAISE EXCEPTION 'Maximum % devices per user exceeded. Please delete unused devices before registering new ones.', max_devices
      USING ERRCODE = '42501', -- insufficient_privilege
            HINT = 'You can have up to 10 devices registered at once';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public';

-- Apply trigger BEFORE INSERT
DROP TRIGGER IF EXISTS devices_rate_limit_check ON devices;

CREATE TRIGGER devices_rate_limit_check
  BEFORE INSERT ON devices
  FOR EACH ROW
  EXECUTE FUNCTION check_devices_rate_limit();

-- Add comments for documentation
COMMENT ON FUNCTION check_devices_rate_limit() IS
'Enforces device count limit (max 10 per user).
Prevents spam device registrations.
Users must delete old devices before registering new ones if at limit.';

COMMENT ON TRIGGER devices_rate_limit_check ON devices IS
'Blocks device registration if user already has 10 devices.
Runs BEFORE INSERT to prevent spam.
Generous limit allows multiple platforms (Windows, macOS, Android, iOS, Linux, etc.).';

-- Verify trigger is installed
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'devices_rate_limit_check'
      AND tgrelid = 'devices'::regclass
  ) THEN
    RAISE EXCEPTION 'Failed to create devices_rate_limit_check trigger';
  END IF;

  RAISE NOTICE '✓ Device rate limiting trigger installed successfully';
  RAISE NOTICE '  - Max: 10 devices per user';
  RAISE NOTICE '  - Protection: Prevents device spam';
  RAISE NOTICE '  - Users must delete old devices to register new ones';
END $$;
