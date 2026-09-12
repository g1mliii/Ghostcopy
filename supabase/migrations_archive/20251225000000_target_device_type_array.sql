-- Change target_device_type from single enum to array of enums
-- This allows sending clipboard items to multiple device types simultaneously
-- Example: Send to both 'windows' and 'ios' but not 'android' or 'macos'

-- Step 1: Drop the old index that uses target_device_type as a scalar
DROP INDEX IF EXISTS idx_clipboard_target_device;

-- Step 2: Change column type from device_type_enum to device_type_enum[]
ALTER TABLE clipboard
  ALTER COLUMN target_device_type TYPE device_type_enum[]
  USING CASE
    WHEN target_device_type IS NULL THEN NULL
    ELSE ARRAY[target_device_type]
  END;

-- Step 3: Create new index for array lookups
-- This helps when filtering clipboard items by user and target device types
CREATE INDEX idx_clipboard_target_device_array ON clipboard
  USING GIN (user_id, target_device_type);

-- Step 4: Update comment
COMMENT ON COLUMN clipboard.target_device_type IS
  'Target device types array for notifications. NULL = broadcast to all devices, array = only send to those device types (e.g., [''windows'', ''ios''])';
