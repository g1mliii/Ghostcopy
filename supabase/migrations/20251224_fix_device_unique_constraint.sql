-- Fix device unique constraint for upsert
-- Problem: Expression-based unique index can't be used with ON CONFLICT
-- Solution: Add proper UNIQUE CONSTRAINT on columns

-- Drop the expression-based unique index
DROP INDEX IF EXISTS idx_devices_user_type_name;

-- Add a proper unique constraint on the columns
-- This works with ON CONFLICT clause in upsert operations
ALTER TABLE devices
ADD CONSTRAINT devices_user_type_name_unique
UNIQUE (user_id, device_type, device_name);

-- Re-create indexes for performance (not unique, just for queries)
CREATE INDEX IF NOT EXISTS idx_devices_last_active
  ON devices(last_active DESC);

CREATE INDEX IF NOT EXISTS idx_devices_fcm_token
  ON devices(user_id, device_type)
  WHERE fcm_token IS NOT NULL;
