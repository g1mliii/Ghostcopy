-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-31 23:22:33 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Migration: Allow cleanup of anonymous accounts while protecting permanent accounts
-- Issue: Previous migration was too strict - blocked legitimate anonymous account cleanup
-- Fix: Allow cleanup if target is anonymous OR if cleaning own account

-- ============================================================================
-- Fix #1: cleanup_user_data - Allow anonymous account cleanup
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_user_data(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_anonymous boolean;
BEGIN
  -- Check if target user is anonymous
  SELECT is_anonymous INTO v_is_anonymous
  FROM auth.users
  WHERE id = p_user_id;

  -- SECURITY CHECK: Allow if cleaning own account OR if target is anonymous
  IF auth.uid() != p_user_id AND NOT COALESCE(v_is_anonymous, false) THEN
    RAISE EXCEPTION 'Unauthorized: Cannot delete permanent account data for other users';
  END IF;

  -- Delete clipboard items for the user
  DELETE FROM clipboard WHERE user_id = p_user_id;

  -- Delete device records for the user
  DELETE FROM devices WHERE user_id = p_user_id;

  -- Delete passphrases/encryption keys for the user (if table exists)
  BEGIN
    DELETE FROM passphrases WHERE user_id = p_user_id;
  EXCEPTION WHEN undefined_table THEN
    NULL;
  END;

  -- Delete mobile link tokens for the user
  DELETE FROM mobile_link_tokens WHERE user_id = p_user_id;
END;
$$;

COMMENT ON FUNCTION cleanup_user_data(uuid) IS
  'Deletes all data for a user. SECURITY: Allows cleanup of own data OR anonymous accounts (temporary accounts). Blocks cleanup of other users permanent accounts.';


-- ============================================================================
-- Fix #2: cleanup_old_clipboard_items - Allow anonymous account cleanup
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_old_clipboard_items(p_user_id uuid, p_keep_count integer DEFAULT 15)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_to_delete RECORD;
  v_is_anonymous boolean;
BEGIN
  -- Check if target user is anonymous
  SELECT is_anonymous INTO v_is_anonymous
  FROM auth.users
  WHERE id = p_user_id;

  -- SECURITY CHECK: Allow if cleaning own account OR if target is anonymous
  IF auth.uid() != p_user_id AND NOT COALESCE(v_is_anonymous, false) THEN
    RAISE EXCEPTION 'Unauthorized: Cannot delete clipboard items for other permanent accounts';
  END IF;

  -- Validate parameter
  IF p_keep_count < 0 THEN
    RAISE EXCEPTION 'Invalid parameter: p_keep_count must be >= 0';
  END IF;

  -- Delete old clipboard items AND their storage files
  FOR v_to_delete IN
    SELECT id, storage_path
    FROM clipboard
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    OFFSET p_keep_count
  LOOP
    -- Delete storage file if it exists
    IF v_to_delete.storage_path IS NOT NULL THEN
      BEGIN
        PERFORM storage.delete_object('clipboard-files', v_to_delete.storage_path);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'Failed to delete storage file %: %', v_to_delete.storage_path, SQLERRM;
      END;
    END IF;

    DELETE FROM clipboard WHERE id = v_to_delete.id;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION cleanup_old_clipboard_items(uuid, integer) IS
  'Deletes old clipboard items for a user. SECURITY: Allows cleanup of own items OR anonymous account items (temporary). Blocks cleanup for other permanent accounts.';
