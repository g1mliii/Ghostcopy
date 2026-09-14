-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-25 05:29:09 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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

-- Step 3: Create new index for array lookups (GIN index on array only)
-- This helps when filtering clipboard items by target device types
CREATE INDEX idx_clipboard_target_device_array ON clipboard
  USING GIN (target_device_type);

-- Step 4: Create regular index for user_id + created_at (most common query pattern)
CREATE INDEX IF NOT EXISTS idx_clipboard_user_created ON clipboard(user_id, created_at DESC);

-- Step 5: Update comment
COMMENT ON COLUMN clipboard.target_device_type IS
  'Target device types array for notifications. NULL = broadcast to all devices, array = only send to those device types (e.g., [''windows'', ''ios''])';
