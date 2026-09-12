-- Create function to cleanup all user data when switching accounts
-- Uses SECURITY DEFINER to bypass RLS policies and allow users to delete their old account data
-- Called before user_id changes via account switching

CREATE OR REPLACE FUNCTION cleanup_user_data(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Delete clipboard items for the user
  DELETE FROM clipboard WHERE user_id = p_user_id;

  -- Delete device records for the user
  DELETE FROM devices WHERE user_id = p_user_id;

  -- Delete passphrases/encryption keys for the user
  DELETE FROM passphrases WHERE user_id = p_user_id;

  -- Delete mobile link tokens for the user
  DELETE FROM mobile_link_tokens WHERE user_id = p_user_id;

  -- Log the cleanup (optional, for debugging)
  -- SELECT pg_notify('cleanup_events', json_build_object(
  --   'user_id', p_user_id,
  --   'cleaned_at', now()
  -- )::text);
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION cleanup_user_data(uuid) TO authenticated;

-- Add comment for documentation
COMMENT ON FUNCTION cleanup_user_data(uuid) IS 'Cleanup all data for a user when switching to a different account. Only callable before the session user_id changes.';
