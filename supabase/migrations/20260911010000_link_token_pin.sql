-- QR device-linking: add a PIN to the link token.
--
-- The QR previously carried the account link token AND the E2E passphrase,
-- with the passphrase "encrypted" using a key stored in the same payload - so a
-- photograph of the QR yielded both the passphrase and a redeemable account
-- session. The passphrase has been removed from the QR entirely (it is now
-- typed by hand on each device), and the token is bound to a 6-digit PIN shown
-- only on the sending device's screen.
--
-- The PIN is matched as part of the atomic consume in exchange-link-token, so a
-- wrong PIN matches no row and does NOT burn the single-use token.
--
-- Run in the Supabase SQL editor. Idempotent.

BEGIN;

ALTER TABLE public.mobile_link_tokens
  ADD COLUMN IF NOT EXISTS pin_hash text;

-- Any token minted before this migration has no PIN and can never be redeemed
-- by the new function. They expire within 5 minutes anyway; clearing them just
-- avoids confusing "expired" errors in the meantime.
DELETE FROM public.mobile_link_tokens WHERE pin_hash IS NULL;

-- New rows must carry a PIN. NOT VALID is unnecessary - the table is empty now.
ALTER TABLE public.mobile_link_tokens
  DROP CONSTRAINT IF EXISTS mobile_link_tokens_pin_hash_required;

ALTER TABLE public.mobile_link_tokens
  ADD CONSTRAINT mobile_link_tokens_pin_hash_required
  CHECK (pin_hash IS NOT NULL AND pin_hash ~ '^[a-f0-9]{64}$');

COMMIT;
