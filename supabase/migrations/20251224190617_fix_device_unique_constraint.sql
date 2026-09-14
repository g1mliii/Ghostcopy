-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-24 19:06:17 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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
