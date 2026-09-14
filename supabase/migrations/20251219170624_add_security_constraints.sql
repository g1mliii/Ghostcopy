-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 17:06:24 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add security constraints to clipboard table

-- 1. Add CHECK constraint for content length (max 100KB to prevent large payload attacks)
ALTER TABLE public.clipboard 
ADD CONSTRAINT clipboard_content_length_check 
CHECK (length(content) <= 102400);

-- 2. Add CHECK constraint for device_type to only allow valid values
ALTER TABLE public.clipboard 
ADD CONSTRAINT clipboard_device_type_check 
CHECK (device_type IN ('windows', 'macos', 'android', 'ios', 'linux'));

-- 3. Add CHECK constraint for device_name length
ALTER TABLE public.clipboard 
ADD CONSTRAINT clipboard_device_name_length_check 
CHECK (device_name IS NULL OR length(device_name) <= 255);

-- 4. Add index on user_id and created_at for efficient queries
CREATE INDEX IF NOT EXISTS idx_clipboard_user_created 
ON public.clipboard(user_id, created_at DESC);

-- 5. Add index on user_id for RLS policy performance
CREATE INDEX IF NOT EXISTS idx_clipboard_user_id 
ON public.clipboard(user_id);

-- 6. Add table comment for documentation
COMMENT ON TABLE public.clipboard IS 'Stores clipboard synchronization history with RLS enabled for user privacy';

-- 7. Add column comments for security awareness
COMMENT ON COLUMN public.clipboard.content IS 'Clipboard text content - max 100KB, validated and sanitized by application';
COMMENT ON COLUMN public.clipboard.user_id IS 'User ID from auth.users - enforced by RLS policies';
COMMENT ON COLUMN public.clipboard.device_type IS 'Device platform - must be one of: windows, macos, android, ios, linux';
