-- App store references for parent-managed setup, so a store's consent
-- withdrawal reaches the same revoke path as a parent's withdrawal in the KWS
-- portal. See docs/store-age-signals.md.
--
-- ref_hash is an HMAC of the store's identifier (Apple appTransactionId,
-- Google Play installId) under the consent function's key. The raw identifier
-- is never stored. Rows go with their request (ON DELETE CASCADE), so they
-- share its retention.
CREATE TABLE private.store_consent_refs (
  ref_hash text NOT NULL CHECK (ref_hash ~ '^[a-f0-9]{64}$'),
  store text NOT NULL CHECK (store IN ('app_store', 'google_play')),
  request_id uuid NOT NULL REFERENCES private.parental_consent_requests(id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (store, ref_hash, request_id)
);
CREATE INDEX store_consent_refs_request ON private.store_consent_refs(request_id);
ALTER TABLE private.store_consent_refs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.store_consent_refs FROM PUBLIC, anon, authenticated;
GRANT ALL ON private.store_consent_refs TO service_role;

CREATE FUNCTION public.store_consent_service(p_action text, p_data jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  item record;
  revoked jsonb := '[]'::jsonb;
BEGIN
  IF p_data->>'store' NOT IN ('app_store','google_play')
    OR coalesce(p_data->>'refHash','') !~ '^[a-f0-9]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Valid store reference required';
  END IF;
  IF p_action = 'bind' THEN
    -- The first binding time is kept: a withdrawal signed after it applies.
    INSERT INTO private.store_consent_refs(ref_hash,store,request_id)
      SELECT p_data->>'refHash',p_data->>'store',id FROM private.parental_consent_requests
        WHERE id=(p_data->>'requestId')::uuid
      ON CONFLICT DO NOTHING;
    RETURN '{}'::jsonb;
  ELSIF p_action = 'revoke' THEN
    -- A withdrawal signed before this reference was bound belongs to an
    -- earlier consent and cannot revoke a later one (replay or late retry).
    FOR item IN SELECT r.request_id, q.status FROM private.store_consent_refs r
        JOIN private.parental_consent_requests q ON q.id=r.request_id
        WHERE r.store=p_data->>'store' AND r.ref_hash=p_data->>'refHash'
          AND r.recorded_at <= (p_data->>'signedAt')::timestamptz
        ORDER BY r.request_id FOR UPDATE OF q LOOP
      IF item.status <> 'revoked' THEN
        PERFORM public.consent_service('revoke', jsonb_build_object('id', item.request_id));
        INSERT INTO private.consent_audit(request_id,action,notice_version,verification_method)
          SELECT id,'store_withdrew_consent',notice_version,p_data->>'store'
            FROM private.parental_consent_requests WHERE id=item.request_id;
        revoked := revoked || to_jsonb(item.request_id);
      END IF;
    END LOOP;
    RETURN revoked;
  END IF;
  RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported store consent operation';
END $$;
REVOKE ALL ON FUNCTION public.store_consent_service(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.store_consent_service(text,jsonb) TO service_role;
