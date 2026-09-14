-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-24 22:25:43 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix clipboard table id generation for partitioned tables
--
-- Problem: Partitioned tables don't automatically inherit IDENTITY sequences from parent
-- Solution: Use a sequence with nextval() as default value
--
-- This fixes: PostgrestException - null value in column "id" violates not-null constraint

-- Step 1: Create a sequence if it doesn't exist
CREATE SEQUENCE IF NOT EXISTS clipboard_id_seq;

-- Step 2: Set the sequence to start from the current max ID + 1 to avoid conflicts
SELECT setval('clipboard_id_seq', COALESCE((SELECT MAX(id) FROM clipboard), 0) + 1, false);

-- Step 3: Set the default value for id column to use the sequence
-- This works for both parent and partition tables
ALTER TABLE clipboard ALTER COLUMN id SET DEFAULT nextval('clipboard_id_seq');

-- Step 4: Make sure the sequence is owned by the id column for proper cleanup
ALTER SEQUENCE clipboard_id_seq OWNED BY clipboard.id;

-- Verification comment
COMMENT ON SEQUENCE clipboard_id_seq IS 'Auto-increment sequence for clipboard.id across all partitions';
