-- Create mobile_link_tokens table for QR code authentication
-- This table stores time-limited tokens for linking mobile devices to anonymous users

CREATE TABLE IF NOT EXISTS mobile_link_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  token text UNIQUE NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- Create index for faster token lookups
CREATE INDEX idx_mobile_link_tokens_token ON mobile_link_tokens(token);
CREATE INDEX idx_mobile_link_tokens_user_id ON mobile_link_tokens(user_id);
CREATE INDEX idx_mobile_link_tokens_expires_at ON mobile_link_tokens(expires_at);

-- Enable Row Level Security
ALTER TABLE mobile_link_tokens ENABLE ROW LEVEL SECURITY;

-- Policy: Users can create their own tokens
CREATE POLICY "Users can create their own tokens"
  ON mobile_link_tokens
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

-- Policy: Tokens are publicly readable for verification (only non-expired)
-- This allows mobile apps to verify tokens without being authenticated
CREATE POLICY "Tokens are publicly readable for verification"
  ON mobile_link_tokens
  FOR SELECT
  TO anon, authenticated
  USING (expires_at > now());

-- Auto-cleanup function for expired tokens
CREATE OR REPLACE FUNCTION cleanup_expired_mobile_link_tokens()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM mobile_link_tokens
  WHERE expires_at < now();
END;
$$;

-- Comment on table and columns for documentation
COMMENT ON TABLE mobile_link_tokens IS 'Stores time-limited tokens for linking mobile devices to anonymous user sessions via QR codes';
COMMENT ON COLUMN mobile_link_tokens.token IS 'SHA-256 hash of the mobile link token';
COMMENT ON COLUMN mobile_link_tokens.expires_at IS 'Token expiration timestamp (5 minutes from creation)';

-- Note: Run cleanup_expired_mobile_link_tokens() periodically (e.g., hourly)
-- You can set this up as a cron job or run it manually:
-- SELECT cleanup_expired_mobile_link_tokens();
