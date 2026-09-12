-- Add target_device_type column for device-specific notifications
-- This allows users to send clipboard items to specific device types (windows, macos, android, ios)
-- NULL = broadcast to all devices, specific value = only that device type

-- Add column to partitioned parent table (automatically adds to all child partitions)
ALTER TABLE clipboard ADD COLUMN target_device_type text;

-- Add check constraint to ensure only valid device types
ALTER TABLE clipboard ADD CONSTRAINT check_target_device_type
  CHECK (target_device_type IS NULL OR target_device_type IN ('windows', 'macos', 'android', 'ios', 'linux'));

-- Create index for faster filtering on device-targeted queries
-- This index helps when filtering clipboard items by user and target device type
CREATE INDEX idx_clipboard_target_device ON clipboard(user_id, target_device_type, created_at DESC);

-- Add comment for documentation
COMMENT ON COLUMN clipboard.target_device_type IS 'Target device type filter for notifications. NULL = broadcast to all devices, specific value (windows/macos/android/ios/linux) = only send to that device type';
