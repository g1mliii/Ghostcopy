-- QR device-linking: cap the number of PIN guesses a link token will accept.
--
-- Binding the token to a 6-digit PIN stopped a photographed QR from being
-- redeemable on its own, but nothing limited guessing. By design a wrong PIN
-- does not consume the token, and exchange-link-token answers 401 'invalid_pin'
-- for a live token vs 400 'expired' otherwise - a clean oracle. With no
-- throttle, someone who photographs the QR can enumerate the whole 10^6 PIN
-- space against that token, concurrently, for the 5-10 minutes it lives. The
-- PIN is the only thing standing between a photographed QR and a full account
-- session, so the guess count has to be bounded.
--
-- Counting happens in a SECURITY DEFINER function rather than in the edge
-- function because PostgREST cannot express `pin_attempts = pin_attempts + 1`.
-- Doing it as read-then-write in the caller would let concurrent guesses
-- interleave and share a single increment, which is exactly the case that
-- matters here.
--
-- Run in the Supabase SQL editor. Idempotent.

BEGIN;

ALTER TABLE public.mobile_link_tokens
  ADD COLUMN IF NOT EXISTS pin_attempts integer NOT NULL DEFAULT 0;

-- Records one failed PIN guess against a token.
--
-- Returns whether the token was live (so the caller can still distinguish
-- wrong-PIN from expired) and whether this guess exhausted the allowance, in
-- which case the token is destroyed and the user must generate a new QR.
CREATE OR REPLACE FUNCTION public.register_link_token_pin_failure(
  p_token text,
  p_max_attempts integer DEFAULT 5
)
RETURNS TABLE (token_live boolean, attempts_exhausted boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_attempts integer;
BEGIN
  -- Single statement, so concurrent guesses serialise on the row lock and each
  -- one is counted.
  UPDATE public.mobile_link_tokens
     SET pin_attempts = pin_attempts + 1
   WHERE token = p_token
     AND expires_at > now()
  RETURNING pin_attempts INTO v_attempts;

  IF NOT FOUND THEN
    -- Unknown or already expired: nothing to count, and the caller reports
    -- 'expired' either way.
    RETURN QUERY SELECT false, false;
    RETURN;
  END IF;

  IF v_attempts >= p_max_attempts THEN
    DELETE FROM public.mobile_link_tokens WHERE token = p_token;
    RETURN QUERY SELECT true, true;
    RETURN;
  END IF;

  RETURN QUERY SELECT true, false;
END;
$$;

-- Only the edge function (service role) may count attempts. Exposing this to
-- anon/authenticated would hand out a way to burn anyone's token by guessing.
REVOKE ALL ON FUNCTION public.register_link_token_pin_failure(text, integer)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.register_link_token_pin_failure(text, integer)
  FROM anon;
REVOKE ALL ON FUNCTION public.register_link_token_pin_failure(text, integer)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION public.register_link_token_pin_failure(text, integer)
  TO service_role;

COMMIT;
