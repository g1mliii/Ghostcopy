-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:48:39 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Migrate existing content to clipboard_content table
INSERT INTO clipboard_content (id, content)
SELECT id, content FROM clipboard
ON CONFLICT (id) DO NOTHING;

-- Drop content column from clipboard table
ALTER TABLE clipboard DROP COLUMN IF EXISTS content;

-- Add expires_at column for time-based cleanup
ALTER TABLE clipboard ADD COLUMN IF NOT EXISTS expires_at timestamptz 
DEFAULT (timezone('utc', now()) + interval '30 days');

-- Create index for cleanup queries
CREATE INDEX IF NOT EXISTS idx_clipboard_expires_at 
ON clipboard(user_id, expires_at DESC);
