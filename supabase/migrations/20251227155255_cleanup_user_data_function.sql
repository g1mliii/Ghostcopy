-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-27 15:52:55 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

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
END;
$$;

-- Grant execute permission to authenticated users
GRANT EXECUTE ON FUNCTION cleanup_user_data(uuid) TO authenticated;

-- Add comment for documentation
COMMENT ON FUNCTION cleanup_user_data(uuid) IS 'Cleanup all data for a user when switching to a different account. Only callable before the session user_id changes.';
