-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-19 22:57:36 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Add encryption_version column to track encryption algorithm version
-- This allows for future encryption algorithm upgrades
ALTER TABLE clipboard ADD COLUMN encryption_version smallint DEFAULT 1;

-- Add index for encryption_version (useful if we need to migrate old data)
CREATE INDEX idx_clipboard_encryption_version ON clipboard(encryption_version);
