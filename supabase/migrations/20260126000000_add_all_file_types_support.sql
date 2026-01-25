-- Migration: Add support for all file types
-- Date: 2026-01-26
-- Description: Extends content_type_enum to support all file types under 10MB

-- Add new file types to the enum
-- Note: PostgreSQL doesn't allow removing enum values, only adding
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_pdf';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_doc';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_docx';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_txt';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_zip';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_tar';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_gz';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_mp4';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_mp3';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_wav';
ALTER TYPE content_type_enum ADD VALUE IF NOT EXISTS 'file_other';

-- Update the constraint to handle all file types
ALTER TABLE clipboard DROP CONSTRAINT IF EXISTS check_storage_for_images;

ALTER TABLE clipboard ADD CONSTRAINT check_storage_for_files
  CHECK (
    (content_type IN ('text', 'html', 'markdown') AND storage_path IS NULL) OR
    (content_type NOT IN ('text', 'html', 'markdown') AND storage_path IS NOT NULL)
  );

-- Update comment to reflect all file types
COMMENT ON COLUMN clipboard.content_type IS 'Type of clipboard content (text, html, markdown, images, or any file type under 10MB)';
COMMENT ON COLUMN clipboard.storage_path IS 'Supabase Storage path for images/files. NULL for text content. Format: user_id/clip_id/filename';

-- Update comment for metadata to mention original filename preservation
COMMENT ON COLUMN clipboard.metadata IS 'JSON metadata: {width, height, thumbnail_url, original_filename}. original_filename is preserved for all file types.';
