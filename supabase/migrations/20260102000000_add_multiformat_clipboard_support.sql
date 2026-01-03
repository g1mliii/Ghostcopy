-- Migration: Add multi-format clipboard support (images, rich text)
-- Date: 2026-01-02
-- Description: Extends clipboard table to support images, HTML, Markdown with Supabase Storage

-- Content type enum for clipboard items
CREATE TYPE content_type_enum AS ENUM (
  'text',
  'html',
  'markdown',
  'image_png',
  'image_jpeg',
  'image_gif'
);

-- Rich text format enum
CREATE TYPE rich_text_format_enum AS ENUM ('html', 'markdown');

-- Extend clipboard table with new columns
ALTER TABLE clipboard
  ADD COLUMN content_type content_type_enum NOT NULL DEFAULT 'text',
  ADD COLUMN storage_path text,
  ADD COLUMN file_size_bytes bigint,
  ADD COLUMN mime_type text,
  ADD COLUMN metadata jsonb,
  ADD COLUMN rich_text_format rich_text_format_enum;

-- Add constraints
ALTER TABLE clipboard
  ADD CONSTRAINT check_storage_for_images
    CHECK (
      (content_type IN ('text', 'html', 'markdown') AND storage_path IS NULL) OR
      (content_type IN ('image_png', 'image_jpeg', 'image_gif') AND storage_path IS NOT NULL)
    ),
  ADD CONSTRAINT check_file_size_limit
    CHECK (file_size_bytes IS NULL OR file_size_bytes <= 10485760); -- 10MB limit

-- Create indexes for performance
CREATE INDEX idx_clipboard_content_type ON clipboard (user_id, content_type, created_at DESC);
CREATE INDEX idx_clipboard_search ON clipboard USING gin(to_tsvector('english', content));
CREATE INDEX idx_clipboard_storage_path ON clipboard (storage_path) WHERE storage_path IS NOT NULL;

-- Migrate existing records to new schema
UPDATE clipboard
SET content_type = 'text',
    mime_type = 'text/plain'
WHERE content_type IS NULL;

-- Add comments for documentation
COMMENT ON COLUMN clipboard.content_type IS 'Type of clipboard content (text, html, markdown, image_png, image_jpeg, image_gif)';
COMMENT ON COLUMN clipboard.storage_path IS 'Supabase Storage path for images/files. NULL for text content. Format: user_id/clip_id/filename';
COMMENT ON COLUMN clipboard.file_size_bytes IS 'File size in bytes for upload progress and quota tracking';
COMMENT ON COLUMN clipboard.mime_type IS 'Original MIME type from clipboard (e.g., image/png, text/html)';
COMMENT ON COLUMN clipboard.metadata IS 'JSON metadata: {width, height, thumbnail_url, original_filename}';
COMMENT ON COLUMN clipboard.rich_text_format IS 'Format for rich text content (html or markdown)';
