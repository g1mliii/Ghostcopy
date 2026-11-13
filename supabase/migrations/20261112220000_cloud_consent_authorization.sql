-- No existing account is assumed to be adult. Deploy with the matching client
-- and mandatory-update plan; old clients cannot bypass authorization with RLS.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO service_role;

-- Staging preserves already distributed clients until the coordinated cutover.
-- Known classified accounts are always checked. Child consent cannot be enabled
-- until unknown/old clients are denied too. Never use this switch as a bypass
-- after launching child support.
CREATE TABLE private.cloud_consent_settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enforce_all_accounts boolean NOT NULL DEFAULT false,
  child_consent_enabled boolean NOT NULL DEFAULT false,
  CHECK (NOT child_consent_enabled OR enforce_all_accounts)
);
INSERT INTO private.cloud_consent_settings DEFAULT VALUES;
ALTER TABLE private.cloud_consent_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.cloud_consent_settings FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.cloud_consent_settings TO service_role;

CREATE TABLE public.cloud_authorizations (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  account_kind text NOT NULL CHECK (account_kind IN ('adult', 'parent_managed')),
  country text NOT NULL CHECK (country ~ '^[A-Z]{2}$'),
  notice_version text NOT NULL,
  status text NOT NULL CHECK (status IN ('authorized', 'revoked')),
  cloud_sync boolean NOT NULL DEFAULT false,
  file_sync boolean NOT NULL DEFAULT false,
  valid_until timestamptz,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (account_kind <> 'parent_managed' OR valid_until IS NOT NULL)
);
ALTER TABLE public.cloud_authorizations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cloud_authorizations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cloud_authorizations TO authenticated;
GRANT ALL ON public.cloud_authorizations TO service_role;
CREATE POLICY own_cloud_authorization ON public.cloud_authorizations
  FOR SELECT TO authenticated USING (user_id = (SELECT auth.uid()));

CREATE TABLE private.parental_consent_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_hash text NOT NULL UNIQUE CHECK (claim_hash ~ '^[a-f0-9]{64}$'),
  parent_hash text NOT NULL CHECK (parent_hash ~ '^[a-f0-9]{64}$'),
  age integer NOT NULL CHECK (age BETWEEN 5 AND 17),
  country text NOT NULL CHECK (country ~ '^[A-Z]{2}$'),
  notice_version text NOT NULL,
  status text NOT NULL DEFAULT 'initiating'
    CHECK (status IN ('initiating', 'pending', 'authorized', 'revoked', 'denied')),
  kws_request_id text UNIQUE,
  requested_at timestamptz,
  bound_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  cloud_sync boolean NOT NULL DEFAULT false,
  file_sync boolean NOT NULL DEFAULT false,
  approved_at timestamptz,
  valid_until timestamptz,
  requires_new_consent boolean NOT NULL DEFAULT false,
  parent_can_manage boolean NOT NULL DEFAULT true,
  last_checked_at timestamptz,
  refresh_lease_until timestamptz,
  revision bigint NOT NULL DEFAULT 0,
  last_event_at timestamptz NOT NULL DEFAULT '-infinity',
  file_revoked_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '14 days',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX parental_consent_parent ON private.parental_consent_requests(parent_hash);
CREATE INDEX parental_consent_expiry ON private.parental_consent_requests(expires_at)
  WHERE bound_user_id IS NULL;

CREATE TABLE private.consent_events (
  event_hash text PRIMARY KEY CHECK (event_hash ~ '^[a-f0-9]{64}$'),
  request_id uuid REFERENCES private.parental_consent_requests(id) ON DELETE SET NULL,
  event_name text NOT NULL,
  event_at timestamptz NOT NULL,
  processed boolean NOT NULL DEFAULT false,
  received_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE private.consent_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_id uuid,
  action text NOT NULL,
  notice_version text NOT NULL,
  verification_method text,
  cloud_sync boolean NOT NULL DEFAULT false,
  file_sync boolean NOT NULL DEFAULT false,
  recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE private.consent_rate_limits (
  bucket text NOT NULL,
  window_start timestamptz NOT NULL,
  request_count integer NOT NULL,
  PRIMARY KEY (bucket, window_start)
);
CREATE TABLE private.kws_deletion_queue (
  subject_id uuid PRIMARY KEY,
  attempts integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

DO $$ DECLARE item record; BEGIN
  FOR item IN SELECT tablename FROM pg_tables WHERE schemaname = 'private'
    AND tablename IN ('parental_consent_requests', 'consent_events', 'consent_audit',
      'consent_rate_limits', 'kws_deletion_queue') LOOP
    EXECUTE format('ALTER TABLE private.%I ENABLE ROW LEVEL SECURITY', item.tablename);
    EXECUTE format('REVOKE ALL ON private.%I FROM PUBLIC, anon, authenticated', item.tablename);
    EXECUTE format('GRANT ALL ON private.%I TO service_role', item.tablename);
  END LOOP;
END $$;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA private TO service_role;

CREATE FUNCTION public.has_cloud_access() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT (NOT EXISTS (SELECT 1 FROM public.cloud_authorizations WHERE user_id = (SELECT auth.uid()))
      AND (SELECT auth.uid()) IS NOT NULL
      AND NOT (SELECT enforce_all_accounts FROM private.cloud_consent_settings))
    OR EXISTS (SELECT 1 FROM public.cloud_authorizations
    WHERE user_id = (SELECT auth.uid()) AND status = 'authorized' AND cloud_sync
      AND notice_version = '2026-11-12-v3'
      AND (account_kind = 'adult' OR valid_until > statement_timestamp()));
$$;
CREATE FUNCTION public.has_cloud_file_access() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT public.has_cloud_access() AND EXISTS (
    SELECT 1 FROM public.cloud_authorizations
    WHERE user_id = (SELECT auth.uid()) AND file_sync)
    OR ((SELECT auth.uid()) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM public.cloud_authorizations WHERE user_id = (SELECT auth.uid()))
      AND NOT (SELECT enforce_all_accounts FROM private.cloud_consent_settings));
$$;
CREATE FUNCTION public.requires_cloud_encryption() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT EXISTS (SELECT 1 FROM public.cloud_authorizations
    WHERE user_id = (SELECT auth.uid()) AND account_kind = 'parent_managed');
$$;
REVOKE ALL ON FUNCTION public.has_cloud_access(), public.has_cloud_file_access(),
  public.requires_cloud_encryption() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_cloud_access(), public.has_cloud_file_access(),
  public.requires_cloud_encryption() TO authenticated;

-- Restrictive policies AND with all historical permissive ownership policies.
-- Cover legacy tables and direct partition paths as well as the current table.
DO $$ DECLARE item record; expression text; BEGIN
  FOR item IN SELECT c.table_name FROM information_schema.columns c
    WHERE c.table_schema = 'public' AND c.column_name = 'user_id'
      AND (c.table_name IN ('clipboard', 'clipboard_test', 'devices', 'mobile_link_tokens')
        OR c.table_name ~ '^clipboard_p[0-9]+$') LOOP
    expression := '(SELECT public.has_cloud_access())';
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
      AND table_name = item.table_name AND column_name = 'is_encrypted') THEN
      expression := expression ||
        ' AND (NOT (SELECT public.requires_cloud_encryption()) OR is_encrypted = true)';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
      AND table_name = item.table_name AND column_name = 'storage_path') THEN
      expression := expression ||
        ' AND (storage_path IS NULL OR (SELECT public.has_cloud_file_access()))';
    END IF;
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', item.table_name);
    EXECUTE format('CREATE POLICY consent_read ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING (%s)',
      item.table_name, expression);
    EXECUTE format('CREATE POLICY consent_insert ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (%s)',
      item.table_name, expression);
    EXECUTE format('CREATE POLICY consent_update ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)',
      item.table_name, expression, expression);
  END LOOP;
  IF to_regclass('public.clipboard_content') IS NOT NULL THEN
    -- The old content table has no encryption marker. Parent-managed clients
    -- must use the encrypted current schema, not this historical alternate path.
    CREATE POLICY consent_legacy_content ON public.clipboard_content AS RESTRICTIVE
      FOR ALL TO authenticated USING (
        (SELECT public.has_cloud_access()) AND NOT (SELECT public.requires_cloud_encryption()))
      WITH CHECK ((SELECT public.has_cloud_access()) AND NOT (SELECT public.requires_cloud_encryption()));
  END IF;
END $$;

-- These two SECURITY DEFINER functions bypass table RLS. Keep their existing
-- token handover behavior behind the same authorization check.
ALTER FUNCTION public.claim_fcm_token(uuid, text) SET SCHEMA private;
ALTER FUNCTION public.claim_wns_channel(uuid, text) SET SCHEMA private;
REVOKE ALL ON FUNCTION private.claim_fcm_token(uuid, text),
  private.claim_wns_channel(uuid, text) FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.claim_fcm_token(p_device_id uuid, p_token text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$ BEGIN
  IF NOT public.has_cloud_access() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Cloud authorization required';
  END IF;
  RETURN private.claim_fcm_token(p_device_id, p_token);
END $$;
CREATE FUNCTION public.claim_wns_channel(p_device_id uuid, p_uri text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$ BEGIN
  IF NOT public.has_cloud_access() THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Cloud authorization required';
  END IF;
  RETURN private.claim_wns_channel(p_device_id, p_uri);
END $$;
REVOKE ALL ON FUNCTION public.claim_fcm_token(uuid, text),
  public.claim_wns_channel(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_fcm_token(uuid, text),
  public.claim_wns_channel(uuid, text) TO authenticated;

CREATE FUNCTION private.enqueue_kws_deletion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$ BEGIN
  INSERT INTO private.kws_deletion_queue(subject_id) VALUES (OLD.id)
    ON CONFLICT (subject_id) DO NOTHING;
  RETURN OLD;
END $$;
CREATE TRIGGER parental_consent_provider_cleanup BEFORE DELETE
  ON private.parental_consent_requests FOR EACH ROW
  EXECUTE FUNCTION private.enqueue_kws_deletion();
REVOKE ALL ON FUNCTION private.enqueue_kws_deletion() FROM PUBLIC, anon, authenticated;
