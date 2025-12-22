-- Merge clipboard and clipboard_content tables + Add device_type enum
--
-- Benefits:
-- 1. Eliminates 64 foreign key constraints (4 per partition)
-- 2. Reduces write overhead (single insert instead of two)
-- 3. Faster reads (no JOIN required)
-- 4. Postgres TOAST automatically handles large content off-page
-- 5. Device type enum provides type safety and prevents typos

-- Step 1: Create device_type enum for type safety
CREATE TYPE device_type_enum AS ENUM ('windows', 'macos', 'android', 'ios', 'linux');

-- Step 2: Clean up any orphaned clipboard rows without content
-- These are incomplete records that should be removed
DELETE FROM clipboard c
WHERE NOT EXISTS (
  SELECT 1 FROM clipboard_content cc
  WHERE cc.id = c.id AND cc.user_id = c.user_id
);

-- Step 3: Add content column to clipboard parent table
-- This automatically adds to all partition tables
ALTER TABLE clipboard ADD COLUMN content text;

-- Step 4: Migrate any existing data from clipboard_content (if any)
UPDATE clipboard c
SET content = cc.content
FROM clipboard_content cc
WHERE c.id = cc.id AND c.user_id = cc.user_id;

-- Step 5: Make content NOT NULL after migration
ALTER TABLE clipboard ALTER COLUMN content SET NOT NULL;

-- Step 6: Drop clipboard_content table
-- This automatically drops all 64 foreign key constraints
DROP TABLE IF EXISTS clipboard_content CASCADE;

-- Step 7: Drop old text-based CHECK constraints before converting to enum
-- These constraints compare text values, which conflicts with enum type
ALTER TABLE clipboard DROP CONSTRAINT IF EXISTS device_type_check;
ALTER TABLE clipboard DROP CONSTRAINT IF EXISTS check_target_device_type;

-- Step 8: Convert device_type columns to enum type
-- First for device_type (sender's device)
ALTER TABLE clipboard
  ALTER COLUMN device_type TYPE device_type_enum
  USING device_type::device_type_enum;

-- Then for target_device_type (recipient filter)
ALTER TABLE clipboard
  ALTER COLUMN target_device_type TYPE device_type_enum
  USING target_device_type::device_type_enum;

-- Step 9: Add comments
COMMENT ON COLUMN clipboard.content IS 'Encrypted clipboard content. Large content is automatically stored off-page via TOAST.';
COMMENT ON COLUMN clipboard.device_type IS 'Sender device type (windows/macos/android/ios/linux)';
COMMENT ON COLUMN clipboard.target_device_type IS 'Target device type filter. NULL = broadcast to all devices, specific value = only that device type';
