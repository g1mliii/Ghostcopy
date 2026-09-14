-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-22 17:04:12 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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
