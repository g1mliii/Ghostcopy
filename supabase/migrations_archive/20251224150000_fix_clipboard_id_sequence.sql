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
