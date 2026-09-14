-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:48:36 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Create separate content table to keep main table lean
CREATE TABLE IF NOT EXISTS clipboard_content (
  id bigint PRIMARY KEY REFERENCES clipboard(id) ON DELETE CASCADE,
  content text NOT NULL,
  CONSTRAINT content_max_length CHECK (length(content) <= 102400)
);

-- Enable RLS on content table
ALTER TABLE clipboard_content ENABLE ROW LEVEL SECURITY;

-- Create RLS policy (users can only access their own content)
CREATE POLICY "Users can view their own clipboard content"
ON clipboard_content
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM clipboard 
    WHERE clipboard.id = clipboard_content.id 
    AND clipboard.user_id = auth.uid()
  )
);

-- Create index for fast lookups
CREATE INDEX idx_clipboard_content_id ON clipboard_content(id);
