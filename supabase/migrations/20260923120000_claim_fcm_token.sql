-- Let a device take its own push token back from whichever row holds it.
--
-- devices_fcm_token_global_unique allows one row per registration token
-- across the whole table - correct, since a token addresses exactly one app
-- install. But when a phone moves to a new account and the old account's
-- device row is not cleaned up (a cleanup call made with an expired session,
-- an app killed mid-switch), that old row keeps the token. The new account's
-- update then fails on the unique index, and the app's own fallback - delete
-- the other row, then retry - cannot work: RLS scopes the caller to its own
-- rows. Push silently stopped reaching the phone. Seen for real on
-- 2026-09-23: after an account deletion, a guest row from the previous night
-- still held the phone's token and the new guest's row had none.
--
-- Safe to hand the token over: a registration token is a long random secret
-- that only the install holding it knows, so presenting it is proof of being
-- that install. The caller must also own the row receiving it. The other
-- row's token is cleared rather than the row deleted, so that account keeps
-- its device list and simply stops pushing to an install that has left it.

CREATE OR REPLACE FUNCTION public.claim_fcm_token(p_device_id uuid, p_token text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Not signed in';
  END IF;
  -- Registration tokens run to well over a hundred characters; refuse
  -- anything that could not be one rather than clear a row for it.
  IF p_token IS NULL OR length(p_token) < 32 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Not a push token';
  END IF;

  -- Only into a row the caller owns, locked so a concurrent claim for the
  -- same row waits rather than interleaves.
  PERFORM 1 FROM public.devices
  WHERE id = p_device_id AND user_id = auth.uid()
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  UPDATE public.devices SET fcm_token = NULL
  WHERE fcm_token = p_token AND id <> p_device_id;

  UPDATE public.devices SET fcm_token = p_token, last_active = now()
  WHERE id = p_device_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_fcm_token(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_fcm_token(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.claim_fcm_token(uuid, text) IS
  'Give the caller''s device row its push token, clearing it from any other row that still holds it (a stale row from an account this install has left). The caller must own p_device_id.';
