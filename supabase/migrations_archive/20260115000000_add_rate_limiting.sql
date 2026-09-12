-- Add database-level rate limiting to prevent spam attacks
-- Date: 2026-01-15
-- Description: Prevents malicious users from bypassing client-side rate limits
--              by directly calling Supabase API to spam database inserts

/*
SECURITY CONTEXT:
- Client-side rate limiting (500ms) can be bypassed by attackers
- Attacker could spam database directly via Supabase client SDK
- This trigger enforces server-side rate limiting at database level
- Protects against:
  * Database saturation
  * Storage quota exhaustion
  * Edge function quota abuse
  * Cost spikes

CONFIGURATION:
- Max inserts: 10 per minute per user
- Window: Rolling 1-minute window
- Penalty: PostgreSQL exception (blocks INSERT)
- Error code: 42501 (insufficient_privilege)
*/

-- Create table to track user insert rates
CREATE TABLE IF NOT EXISTS user_rate_limit (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  insert_count int NOT NULL DEFAULT 0,
  window_start timestamptz NOT NULL DEFAULT NOW(),
  created_at timestamptz DEFAULT NOW(),
  updated_at timestamptz DEFAULT NOW()
);

-- Index for fast lookups (user_id is PRIMARY KEY, so this is redundant but harmless)
CREATE INDEX IF NOT EXISTS idx_user_rate_limit_user_id ON user_rate_limit(user_id);

-- Enable RLS on rate limit table (only service role can access)
ALTER TABLE user_rate_limit ENABLE ROW LEVEL SECURITY;

-- Policy: Only service role can read/write (users don't need access)
CREATE POLICY service_role_only ON user_rate_limit
  FOR ALL
  USING (false); -- Block all access from regular users

-- Function to check and enforce rate limit
CREATE OR REPLACE FUNCTION check_clipboard_rate_limit()
RETURNS TRIGGER AS $$
DECLARE
  current_count int;
  window_start_time timestamptz;
  max_inserts_per_minute int := 10; -- Max 10 clips per minute per user
  window_duration interval := INTERVAL '1 minute';
BEGIN
  -- Get current rate limit record for this user
  SELECT insert_count, window_start
  INTO current_count, window_start_time
  FROM user_rate_limit
  WHERE user_id = NEW.user_id;

  -- Initialize if user has no rate limit record yet
  IF NOT FOUND THEN
    INSERT INTO user_rate_limit (user_id, insert_count, window_start)
    VALUES (NEW.user_id, 1, NOW())
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
  END IF;

  -- Check if window has expired (rolling 1-minute window)
  IF NOW() - window_start_time > window_duration THEN
    -- Reset window
    UPDATE user_rate_limit
    SET insert_count = 1,
        window_start = NOW(),
        updated_at = NOW()
    WHERE user_id = NEW.user_id;

    RETURN NEW;
  END IF;

  -- Check if user has exceeded rate limit
  IF current_count >= max_inserts_per_minute THEN
    -- Log rate limit violation
    RAISE WARNING 'Rate limit exceeded for user %: % inserts in % seconds',
      NEW.user_id,
      current_count,
      EXTRACT(EPOCH FROM (NOW() - window_start_time));

    -- Block the insert with a clear error message
    RAISE EXCEPTION 'Rate limit exceeded: Maximum % clipboard inserts per minute allowed. Please wait % seconds before trying again.',
      max_inserts_per_minute,
      CEIL(EXTRACT(EPOCH FROM (window_start_time + window_duration - NOW())))
      USING ERRCODE = '42501', -- insufficient_privilege
            HINT = 'Rate limit resets in a rolling 1-minute window';
  END IF;

  -- Increment count within current window
  UPDATE user_rate_limit
  SET insert_count = insert_count + 1,
      updated_at = NOW()
  WHERE user_id = NEW.user_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public';

-- Apply trigger BEFORE INSERT (blocks spam before it hits database)
DROP TRIGGER IF EXISTS clipboard_rate_limit_check ON clipboard;

CREATE TRIGGER clipboard_rate_limit_check
  BEFORE INSERT ON clipboard
  FOR EACH ROW
  EXECUTE FUNCTION check_clipboard_rate_limit();

-- Add comments for documentation
COMMENT ON TABLE user_rate_limit IS
'Tracks clipboard insert rate per user to prevent spam attacks.
Rolling 1-minute window with max 10 inserts per minute.
Cleaned up automatically when user is deleted (CASCADE).';

COMMENT ON FUNCTION check_clipboard_rate_limit() IS
'Enforces database-level rate limiting on clipboard inserts.
Prevents spam attacks that bypass client-side rate limiting.
Max: 10 inserts per minute per user (rolling window).
Returns clear error message with wait time when limit exceeded.';

COMMENT ON TRIGGER clipboard_rate_limit_check ON clipboard IS
'Blocks clipboard inserts that exceed rate limit (10/min per user).
Runs BEFORE INSERT to prevent spam from hitting database.
Part of defense-in-depth security strategy.';

-- Create function to cleanup old rate limit records (optional maintenance)
CREATE OR REPLACE FUNCTION cleanup_stale_rate_limits()
RETURNS void AS $$
BEGIN
  -- Delete rate limit records older than 1 day (no activity)
  DELETE FROM user_rate_limit
  WHERE updated_at < NOW() - INTERVAL '1 day';

  RAISE NOTICE 'Cleaned up stale rate limit records';
END;
$$ LANGUAGE plpgsql
SECURITY DEFINER;

-- Verify trigger is installed
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'clipboard_rate_limit_check'
      AND tgrelid = 'clipboard'::regclass
  ) THEN
    RAISE EXCEPTION 'Failed to create clipboard_rate_limit_check trigger';
  END IF;

  RAISE NOTICE '✓ Rate limiting trigger installed successfully';
  RAISE NOTICE '  - Max: 10 inserts per minute per user';
  RAISE NOTICE '  - Window: Rolling 1-minute';
  RAISE NOTICE '  - Protection: Prevents spam attacks';
END $$;
