-- One cron invocation is one transaction. Bound the work per invocation,
-- persist progress, and keep network work outside clipboard DELETEs.
SET lock_timeout = '5s';

CREATE TABLE public.clipboard_cleanup_cursor (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  last_user_id uuid
);
INSERT INTO public.clipboard_cleanup_cursor(singleton) VALUES (true);
ALTER TABLE public.clipboard_cleanup_cursor ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.clipboard_cleanup_cursor FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.clipboard_cleanup_cursor TO service_role;

CREATE OR REPLACE FUNCTION public.cleanup_old_clipboard_items_deep()
RETURNS TABLE(deleted_count bigint, processed_users bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  cursor_id uuid;
  candidate uuid;
  batch_count integer;
  visited integer := 0;
BEGIN
  SELECT last_user_id INTO cursor_id FROM public.clipboard_cleanup_cursor
    WHERE singleton FOR UPDATE;
  deleted_count := 0;
  processed_users := 0;
  -- Keyset pagination avoids rescanning every clipboard row on each batch.
  FOR candidate IN SELECT id FROM auth.users
    WHERE id > COALESCE(cursor_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ORDER BY id LIMIT 1000
  LOOP
    visited := visited + 1;
    DELETE FROM public.clipboard WHERE id IN (
      SELECT id FROM public.clipboard WHERE user_id = candidate
      ORDER BY created_at DESC, id DESC
      LIMIT (5000 - deleted_count) OFFSET 20
    );
    GET DIAGNOSTICS batch_count = ROW_COUNT;
    deleted_count := deleted_count + batch_count;
    processed_users := processed_users + 1;
    -- Resume this user next time if the deletion budget was exhausted.
    EXIT WHEN deleted_count >= 5000;
    cursor_id := candidate;
  END LOOP;
  IF visited < 1000 AND deleted_count < 5000 THEN cursor_id := NULL; END IF;
  UPDATE public.clipboard_cleanup_cursor SET last_user_id = cursor_id WHERE singleton;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_old_clipboard_items_deep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_old_clipboard_items_deep() TO service_role;
COMMENT ON FUNCTION public.cleanup_old_clipboard_items_deep() IS
'One bounded transaction: visit at most 1000 users and delete at most 5000 rows, retaining the newest 20 per user. Resume via a persistent user cursor.';

-- Atomic upsert serializes both first inserts and increments for a user.
CREATE OR REPLACE FUNCTION public.check_clipboard_rate_limit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE accepted integer;
BEGIN
  INSERT INTO public.user_rate_limit AS limits(user_id, insert_count, window_start, updated_at)
  VALUES (NEW.user_id, 1, clock_timestamp(), clock_timestamp())
  ON CONFLICT (user_id) DO UPDATE SET
    insert_count = CASE WHEN limits.window_start <= clock_timestamp() - interval '1 minute'
      THEN 1 ELSE limits.insert_count + 1 END,
    window_start = CASE WHEN limits.window_start <= clock_timestamp() - interval '1 minute'
      THEN clock_timestamp() ELSE limits.window_start END,
    updated_at = clock_timestamp()
  WHERE limits.insert_count < 10 OR limits.window_start <= clock_timestamp() - interval '1 minute'
  RETURNING insert_count INTO accepted;
  IF accepted IS NULL THEN
    RAISE EXCEPTION 'Rate limit exceeded: Maximum 10 clipboard inserts per minute allowed.'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TABLE public.storage_rate_limits (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('upload', 'download', 'delete')),
  call_count integer NOT NULL,
  window_start timestamptz NOT NULL,
  PRIMARY KEY (user_id, action)
);
CREATE INDEX storage_rate_limits_window ON public.storage_rate_limits(window_start);
ALTER TABLE public.storage_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storage_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.storage_rate_limits TO service_role;

CREATE FUNCTION public.check_storage_rate_limit(p_user_id uuid, p_action text)
RETURNS TABLE(allowed boolean, retry_after_seconds integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  max_calls integer;
  accepted integer;
  started timestamptz;
BEGIN
  max_calls := CASE p_action WHEN 'upload' THEN 20 WHEN 'download' THEN 120 WHEN 'delete' THEN 30 END;
  IF max_calls IS NULL THEN RAISE EXCEPTION 'Invalid storage action'; END IF;
  INSERT INTO public.storage_rate_limits AS limits(user_id, action, call_count, window_start)
  VALUES (p_user_id, p_action, 1, clock_timestamp())
  ON CONFLICT (user_id, action) DO UPDATE SET
    call_count = CASE WHEN limits.window_start <= clock_timestamp() - interval '1 minute'
      THEN 1 ELSE limits.call_count + 1 END,
    window_start = CASE WHEN limits.window_start <= clock_timestamp() - interval '1 minute'
      THEN clock_timestamp() ELSE limits.window_start END
  WHERE limits.call_count < max_calls OR limits.window_start <= clock_timestamp() - interval '1 minute'
  RETURNING call_count INTO accepted;
  allowed := accepted IS NOT NULL;
  retry_after_seconds := 0;
  IF NOT allowed THEN
    SELECT window_start INTO started FROM public.storage_rate_limits
      WHERE user_id = p_user_id AND action = p_action;
    retry_after_seconds := GREATEST(1, CEIL(EXTRACT(EPOCH FROM
      (started + interval '1 minute' - clock_timestamp())))::integer);
  END IF;
  RETURN NEXT;
END;
$$;
REVOKE ALL ON FUNCTION public.check_storage_rate_limit(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_storage_rate_limit(uuid, text) TO service_role;

-- Durable outbox. No FK to auth.users: deletion must survive account removal.
CREATE TABLE public.storage_cleanup_queue (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner_id uuid NOT NULL,
  storage_path text NOT NULL UNIQUE,
  queued_at timestamptz NOT NULL DEFAULT now(),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0,
  CHECK (starts_with(storage_path, owner_id::text || '/'))
);
CREATE INDEX storage_cleanup_queue_due ON public.storage_cleanup_queue(next_attempt_at, id);
ALTER TABLE public.storage_cleanup_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storage_cleanup_queue FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.storage_cleanup_queue TO service_role;
REVOKE ALL ON SEQUENCE public.storage_cleanup_queue_id_seq FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SEQUENCE public.storage_cleanup_queue_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.cleanup_storage_on_clipboard_delete() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF OLD.storage_path IS NOT NULL AND starts_with(OLD.storage_path, OLD.user_id::text || '/') THEN
    INSERT INTO public.storage_cleanup_queue(owner_id, storage_path)
    VALUES (OLD.user_id, OLD.storage_path) ON CONFLICT (storage_path) DO NOTHING;
  END IF;
  RETURN OLD;
END;
$$;
COMMENT ON FUNCTION public.cleanup_storage_on_clipboard_delete() IS
'Queues owner-validated R2 deletions in the same transaction as row deletion. A separate worker batches and retries them; no network or Vault access in this trigger.';

CREATE FUNCTION public.claim_storage_cleanup_batch()
RETURNS SETOF public.storage_cleanup_queue
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  UPDATE public.storage_cleanup_queue SET
    next_attempt_at = now() + interval '5 minutes', attempts = attempts + 1
  WHERE id IN (SELECT id FROM public.storage_cleanup_queue
    WHERE next_attempt_at <= now() ORDER BY next_attempt_at, id
    LIMIT 500 FOR UPDATE SKIP LOCKED)
  RETURNING *;
$$;
REVOKE ALL ON FUNCTION public.claim_storage_cleanup_batch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_storage_cleanup_batch() TO service_role;

CREATE FUNCTION public.acknowledge_storage_cleanup(p_ids bigint[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF cardinality(p_ids) > 500 THEN RAISE EXCEPTION 'Batch too large'; END IF;
  DELETE FROM public.storage_cleanup_queue WHERE id = ANY(p_ids);
END;
$$;
REVOKE ALL ON FUNCTION public.acknowledge_storage_cleanup(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_storage_cleanup(bigint[]) TO service_role;

CREATE FUNCTION public.dispatch_storage_cleanup() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE api_url text; service_key text; batches integer; batch integer;
BEGIN
  SELECT CEIL(count(*) / 500.0)::integer INTO batches FROM (
    SELECT 1 FROM public.storage_cleanup_queue WHERE next_attempt_at <= now() LIMIT 5000
  ) due;
  IF batches = 0 THEN RETURN; END IF;
  SELECT decrypted_secret INTO api_url FROM vault.decrypted_secrets WHERE name = 'supabase_api_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key FROM vault.decrypted_secrets WHERE name = 'fcm_service_role_key' LIMIT 1;
  IF COALESCE(api_url, '') = '' OR COALESCE(service_key, '') = '' THEN
    RAISE EXCEPTION 'Storage cleanup requires supabase_api_url and fcm_service_role_key in Vault';
  END IF;
  -- Match the retention job's 5000-row budget with at most ten 500-key
  -- requests. Each worker claims its own rows with SKIP LOCKED.
  FOR batch IN 1..batches LOOP
    PERFORM net.http_post(
      url := api_url || '/functions/v1/storage-presign',
      headers := jsonb_build_object('Authorization', 'Bearer ' || service_key,
        'apikey', service_key, 'Content-Type', 'application/json'),
      body := '{"action":"delete_queued"}'::jsonb,
      timeout_milliseconds := 30000
    );
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.dispatch_storage_cleanup() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_storage_cleanup() TO service_role;

CREATE INDEX IF NOT EXISTS user_rate_limit_updated_at ON public.user_rate_limit(updated_at);
CREATE OR REPLACE FUNCTION public.cleanup_stale_rate_limits() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM public.user_rate_limit WHERE user_id IN (
    SELECT user_id FROM public.user_rate_limit WHERE updated_at < now() - interval '1 day'
    ORDER BY updated_at LIMIT 5000);
  DELETE FROM public.storage_rate_limits WHERE (user_id, action) IN (
    SELECT user_id, action FROM public.storage_rate_limits WHERE window_start < now() - interval '1 day'
    ORDER BY window_start LIMIT 5000);
  DELETE FROM public.mobile_link_tokens WHERE token IN (
    SELECT token FROM public.mobile_link_tokens WHERE expires_at < now()
    ORDER BY expires_at LIMIT 5000);
END;
$$;

-- Search is performed in the client (including when content is encrypted).
-- These five indexes have no matching access path in the application or jobs.
DROP INDEX IF EXISTS public.idx_clipboard_search;
DROP INDEX IF EXISTS public.idx_clipboard_content_type;
DROP INDEX IF EXISTS public.idx_clipboard_encryption_version;
DROP INDEX IF EXISTS public.idx_clipboard_target_device_type;
DROP INDEX IF EXISTS public.idx_clipboard_user_id_is_encrypted;

-- Only empty, inactive guest accounts are disposable. Never expire a guest
-- that still owns clips/devices, has a live link, or recently refreshed auth.
CREATE FUNCTION public.cleanup_abandoned_anonymous_users() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  DELETE FROM auth.users WHERE id IN (
    SELECT u.id FROM auth.users u
    WHERE u.is_anonymous AND
      COALESCE(u.last_sign_in_at, u.created_at) < now() - interval '30 days'
      AND NOT EXISTS (SELECT 1 FROM public.clipboard c WHERE c.user_id = u.id)
      AND NOT EXISTS (SELECT 1 FROM public.devices d WHERE d.user_id = u.id)
      AND NOT EXISTS (SELECT 1 FROM public.mobile_link_tokens t WHERE t.user_id = u.id AND t.expires_at > now())
      AND NOT EXISTS (SELECT 1 FROM auth.sessions s WHERE s.user_id = u.id
        AND COALESCE(s.updated_at, s.created_at) > now() - interval '30 days')
    ORDER BY u.id LIMIT 1000 FOR UPDATE OF u SKIP LOCKED
  );
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_abandoned_anonymous_users() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_abandoned_anonymous_users() TO service_role;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'cleanup-old-clips-daily';
SELECT cron.schedule('cleanup-old-clips-bounded', '* * * * *',
  'SELECT * FROM public.cleanup_old_clipboard_items_deep()');
SELECT cron.schedule('cleanup-storage-queue', '* * * * *',
  'SELECT public.dispatch_storage_cleanup()');
SELECT cron.schedule('cleanup-expired-transient-data', '*/5 * * * *',
  'SELECT public.cleanup_stale_rate_limits()');
SELECT cron.schedule('cleanup-empty-anonymous-accounts', '17 * * * *',
  'SELECT public.cleanup_abandoned_anonymous_users()');

RESET lock_timeout;
