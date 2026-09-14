-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-07-09 20:11:18 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Security hardening for R2 cleanup and QR account-link tokens.
-- The constraints are NOT VALID so legacy rows do not block rollout; PostgreSQL
-- still enforces them for every new or changed row.

ALTER TABLE public.clipboard
  DROP CONSTRAINT IF EXISTS clipboard_storage_path_owned_by_user

ALTER TABLE public.clipboard
  ADD CONSTRAINT clipboard_storage_path_owned_by_user
  CHECK (
    storage_path IS NULL
    OR storage_path LIKE user_id::text || '/%'
  ) NOT VALID

CREATE OR REPLACE FUNCTION public.cleanup_storage_on_clipboard_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
DECLARE
  supabase_url text;
  service_role_key text;
  full_url text;
  request_body jsonb;
BEGIN
  IF OLD.storage_path IS NULL THEN
    RETURN OLD;
  END IF;

  -- Do not let an invalid legacy row turn the cleanup trigger into a
  -- privileged arbitrary-object delete primitive.
  IF OLD.storage_path NOT LIKE OLD.user_id::text || '/%' THEN
    RAISE WARNING '[Storage Cleanup R2] Refusing path outside row owner prefix. clipboard_id=%', OLD.id;
    RETURN OLD;
  END IF;

  BEGIN
    SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_api_url'
    LIMIT 1;

    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'fcm_service_role_key'
    LIMIT 1;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Storage Cleanup R2] Unable to access Vault secrets: %', SQLERRM;
      RETURN OLD;
  END;

  IF COALESCE(supabase_url, '') = '' OR COALESCE(service_role_key, '') = '' THEN
    RAISE WARNING '[Storage Cleanup R2] Missing vault secrets. clipboard_id=%', OLD.id;
    RETURN OLD;
  END IF;

  full_url := supabase_url || '/functions/v1/storage-presign';
  request_body := jsonb_build_object(
    'action', 'delete',
    'ownerId', OLD.user_id::text,
    'path', OLD.storage_path
  );

  BEGIN
    PERFORM net.http_post(
      url := full_url,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || service_role_key,
        'apikey', service_role_key,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 5000
    );
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Storage Cleanup R2] Failed to delete clipboard_id %: %', OLD.id, SQLERRM;
  END;

  RETURN OLD;
END;
$$

ALTER FUNCTION public.cleanup_storage_on_clipboard_delete() OWNER TO postgres

-- QR payloads now carry a random secret, while the database contains only its
-- SHA-256 hash. Remove the public read policy that exposed those stored values.
DROP POLICY IF EXISTS "Tokens are publicly readable for verification"
ON public.mobile_link_tokens

ALTER POLICY "Users can create their own tokens"
ON public.mobile_link_tokens
WITH CHECK (user_id = (SELECT auth.uid()))

REVOKE SELECT ON TABLE public.mobile_link_tokens FROM PUBLIC, anon, authenticated

GRANT INSERT, DELETE ON TABLE public.mobile_link_tokens TO authenticated

ALTER TABLE public.mobile_link_tokens
  DROP CONSTRAINT IF EXISTS mobile_link_tokens_token_sha256

ALTER TABLE public.mobile_link_tokens
  ADD CONSTRAINT mobile_link_tokens_token_sha256
  CHECK (token ~ '^[a-f0-9]{64}$') NOT VALID

-- This single-use consumption primitive is callable only by the Edge Function
-- through the service role. Its DELETE ... RETURNING makes racing QR scans
-- unable to obtain two sessions.
CREATE OR REPLACE FUNCTION public.consume_mobile_link_token(p_token_hash text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  linked_user_id uuid;
BEGIN
  DELETE FROM public.mobile_link_tokens
  WHERE token = p_token_hash
    AND expires_at > now()
  RETURNING user_id INTO linked_user_id;

  RETURN linked_user_id;
END;
$$

ALTER FUNCTION public.consume_mobile_link_token(text) OWNER TO postgres

REVOKE EXECUTE ON FUNCTION public.consume_mobile_link_token(text)
FROM PUBLIC, anon, authenticated

GRANT EXECUTE ON FUNCTION public.consume_mobile_link_token(text) TO service_role

-- Restore the daily cleanup job if a previous deployment removed it. The
-- existing function is deliberately batched for production-size histories.
SELECT cron.unschedule('cleanup-old-clips-daily')
WHERE EXISTS (
  SELECT 1 FROM cron.job WHERE jobname = 'cleanup-old-clips-daily'
)

SELECT cron.schedule(
  'cleanup-old-clips-daily',
  '0 2 * * *',
  $$SELECT * FROM public.cleanup_old_clipboard_items_deep()$$
);
