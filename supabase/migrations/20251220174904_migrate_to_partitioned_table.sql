-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-20 17:49:04 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Step 1: Drop dependent objects
DROP POLICY IF EXISTS "Users can view their own clipboard content" ON clipboard_content;
DROP TABLE IF EXISTS clipboard_content;

-- Step 2: Create partitioned clipboard table with proper composite key
CREATE TABLE clipboard_new (
  id bigint,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  device_name text,
  device_type text NOT NULL,
  is_public boolean DEFAULT false,
  created_at timestamptz DEFAULT timezone('utc', now()),
  encryption_version smallint DEFAULT 1,
  expires_at timestamptz DEFAULT (timezone('utc', now()) + interval '30 days'),
  PRIMARY KEY (id, user_id),
  CONSTRAINT device_type_check CHECK (device_type = ANY (ARRAY['windows'::text, 'macos'::text, 'android'::text, 'ios'::text, 'linux'::text])),
  CONSTRAINT device_name_check CHECK (device_name IS NULL OR length(device_name) <= 255)
) PARTITION BY HASH (user_id);

-- Step 3: Create 16 partitions
CREATE TABLE clipboard_p0 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE clipboard_p1 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 1);
CREATE TABLE clipboard_p2 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 2);
CREATE TABLE clipboard_p3 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 3);
CREATE TABLE clipboard_p4 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 4);
CREATE TABLE clipboard_p5 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 5);
CREATE TABLE clipboard_p6 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 6);
CREATE TABLE clipboard_p7 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 7);
CREATE TABLE clipboard_p8 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 8);
CREATE TABLE clipboard_p9 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 9);
CREATE TABLE clipboard_p10 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 10);
CREATE TABLE clipboard_p11 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 11);
CREATE TABLE clipboard_p12 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 12);
CREATE TABLE clipboard_p13 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 13);
CREATE TABLE clipboard_p14 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 14);
CREATE TABLE clipboard_p15 PARTITION OF clipboard_new FOR VALUES WITH (MODULUS 16, REMAINDER 15);

-- Step 4: Copy all data
INSERT INTO clipboard_new (id, user_id, device_name, device_type, is_public, created_at, encryption_version, expires_at)
SELECT id, user_id, device_name, device_type, is_public, created_at, encryption_version, expires_at
FROM clipboard
ON CONFLICT DO NOTHING;

-- Step 5: Drop old table and rename new
DROP TABLE clipboard;
ALTER TABLE clipboard_new RENAME TO clipboard;

-- Step 6: Recreate RLS
ALTER TABLE clipboard ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own clipboard items"
ON clipboard
FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own clipboard items"
ON clipboard
FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own clipboard items"
ON clipboard
FOR DELETE
USING (auth.uid() = user_id);

-- Step 7: Recreate content table
CREATE TABLE clipboard_content (
  id bigint,
  user_id uuid NOT NULL,
  content text NOT NULL,
  PRIMARY KEY (id, user_id),
  FOREIGN KEY (id, user_id) REFERENCES clipboard(id, user_id) ON DELETE CASCADE,
  CONSTRAINT content_max_length CHECK (length(content) <= 102400)
);

ALTER TABLE clipboard_content ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own clipboard content"
ON clipboard_content
FOR SELECT
USING (auth.uid() = user_id);

-- Step 8: Recreate indexes
CREATE INDEX idx_clipboard_user_created_desc ON clipboard(user_id, created_at DESC);
CREATE INDEX idx_clipboard_realtime ON clipboard(user_id, id);
CREATE INDEX idx_clipboard_encryption_version ON clipboard(encryption_version);
CREATE INDEX idx_clipboard_expires_at ON clipboard(user_id, expires_at DESC);
CREATE INDEX idx_clipboard_content_id ON clipboard_content(id);
