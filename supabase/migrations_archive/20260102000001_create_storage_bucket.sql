-- Migration: Create Supabase Storage bucket for clipboard files
-- Date: 2026-01-02
-- Description: Sets up storage bucket with RLS policies for secure file access

-- Create storage bucket for clipboard files (private)
INSERT INTO storage.buckets (id, name, public)
VALUES ('clipboard-files', 'clipboard-files', false);

-- RLS Policy: Users can upload their own files
CREATE POLICY "Users upload own files"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'clipboard-files' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- RLS Policy: Users can read their own files
CREATE POLICY "Users read own files"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'clipboard-files' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- RLS Policy: Users can delete their own files
CREATE POLICY "Users delete own files"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'clipboard-files' AND
  auth.uid()::text = (storage.foldername(name))[1]
);

-- Note: File size limit is enforced at application level (10MB)
-- Storage path format: user_id/clip_id/filename.ext
