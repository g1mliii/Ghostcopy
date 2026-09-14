-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-26 18:07:37 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add is_encrypted column to clipboard table
--
-- Purpose: Track which clipboard items are encrypted with user passphrase
-- This enables optional E2E encryption where users can choose to enable/disable
-- encryption with their own passphrase stored in platform secure storage.
--
-- Migration is safe: defaults to false for all existing items (they are plaintext)

-- Add is_encrypted column with default false
-- This automatically applies to all partition tables since clipboard is partitioned
ALTER TABLE clipboard
ADD COLUMN is_encrypted boolean NOT NULL DEFAULT false;

-- Create index for filtering encrypted vs plaintext items
-- Useful for debugging and analytics
CREATE INDEX idx_clipboard_is_encrypted
ON clipboard (user_id, is_encrypted);

-- Add comment for documentation
COMMENT ON COLUMN clipboard.is_encrypted IS
'Indicates if content is encrypted with user passphrase (true) or plaintext (false). Users control encryption by setting a passphrase in app settings.';
