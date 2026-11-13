-- Internal operations for the consent edge function. Only service_role can
-- execute this interface; no client can supply its own authorization evidence.
CREATE FUNCTION public.consent_service(p_action text, p_data jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
  request private.parental_consent_requests;
  previous_request private.parental_consent_requests;
  profile public.cloud_authorizations;
  subject uuid;
  actor uuid;
  changed bigint;
  result jsonb;
  bucket_count integer;
BEGIN
  IF p_action = 'configuration' THEN
    RETURN (SELECT jsonb_build_object('enforced',enforce_all_accounts,
      'childrenEnabled',child_consent_enabled,'noticeVersion','2026-11-12-v3',
      'minimumAge',5,'independentAge',18) FROM private.cloud_consent_settings);
  ELSIF p_action = 'access' THEN
    SELECT * INTO profile FROM public.cloud_authorizations WHERE user_id=(p_data->>'userId')::uuid;
    IF NOT FOUND THEN
      RETURN (SELECT jsonb_build_object('allowed',NOT enforce_all_accounts,
        'fileSync',NOT enforce_all_accounts,'parentManaged',false) FROM private.cloud_consent_settings);
    END IF;
    RETURN jsonb_build_object('allowed',profile.status='authorized' AND profile.cloud_sync
      AND profile.notice_version='2026-11-12-v3'
      AND (profile.account_kind='adult' OR profile.valid_until>now()),
      'fileSync',profile.file_sync,'parentManaged',profile.account_kind='parent_managed');
  ELSIF p_action = 'start' THEN
    IF NOT (SELECT child_consent_enabled AND enforce_all_accounts FROM private.cloud_consent_settings) THEN
      RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='Parent setup is not enabled';
    END IF;
    IF p_data->>'noticeVersion' IS DISTINCT FROM '2026-11-12-v3' THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Current parental notice required';
    END IF;
    FOREACH result IN ARRAY ARRAY[
      jsonb_build_object('key','parent:' || (p_data->>'parentHash'),'limit',4),
      jsonb_build_object('key','global','limit',500)
    ] LOOP
      INSERT INTO private.consent_rate_limits(bucket,window_start,request_count)
        VALUES(result->>'key',date_trunc('hour',now()),1)
      ON CONFLICT(bucket,window_start) DO UPDATE
        SET request_count=private.consent_rate_limits.request_count+1
        WHERE private.consent_rate_limits.request_count < (result->>'limit')::integer
      RETURNING request_count INTO bucket_count;
      IF NOT FOUND THEN
        RAISE EXCEPTION USING ERRCODE='P0001', MESSAGE='Too many consent requests';
      END IF;
    END LOOP;
    INSERT INTO private.parental_consent_requests(claim_hash,parent_hash,age,country,notice_version)
      VALUES(p_data->>'claimHash',p_data->>'parentHash',(p_data->>'age')::integer,
        p_data->>'country','2026-11-12-v3') RETURNING * INTO request;
    RETURN to_jsonb(request);
  ELSIF p_action = 'sent' THEN
    UPDATE private.parental_consent_requests SET status='pending',
      kws_request_id=p_data->>'kwsRequestId',requested_at=now(),revision=revision+1
      WHERE id=(p_data->>'id')::uuid AND status='initiating' RETURNING * INTO request;
    IF NOT FOUND THEN RAISE EXCEPTION 'Consent request changed'; END IF;
    RETURN to_jsonb(request);
  ELSIF p_action = 'lookup' THEN
    SELECT * INTO request FROM private.parental_consent_requests
      WHERE (p_data ? 'claimHash' AND claim_hash=p_data->>'claimHash')
        OR (p_data ? 'id' AND id=(p_data->>'id')::uuid)
        OR (p_data ? 'userId' AND bound_user_id=(p_data->>'userId')::uuid);
    RETURN CASE WHEN FOUND THEN to_jsonb(request) ELSE NULL END;
  ELSIF p_action = 'apply_permissions' THEN
    SELECT * INTO request FROM private.parental_consent_requests
      WHERE id=(p_data->>'id')::uuid FOR UPDATE;
    IF NOT FOUND OR request.revision<>(p_data->>'revision')::bigint
      OR request.kws_request_id IS DISTINCT FROM p_data->>'kwsRequestId'
      OR request.requires_new_consent OR request.kws_request_id IS NULL
      OR (request.bound_user_id IS NULL AND request.expires_at <= now()) THEN
      RETURN NULL;
    END IF;
    previous_request := request;
    UPDATE private.parental_consent_requests SET
      cloud_sync=(p_data->>'cloudSync')::boolean,
      file_sync=(p_data->>'cloudSync')::boolean AND (p_data->>'fileSync')::boolean,
      status=CASE WHEN (p_data->>'cloudSync')::boolean THEN 'authorized'
        WHEN approved_at IS NULL THEN 'pending' ELSE 'revoked' END,
      approved_at=CASE WHEN (p_data->>'cloudSync')::boolean THEN coalesce(approved_at,now()) ELSE approved_at END,
      valid_until=now()+interval '15 minutes',last_checked_at=now(),refresh_lease_until=NULL, revision=revision+1
      WHERE id=request.id RETURNING * INTO request;
    IF request.bound_user_id IS NOT NULL THEN
      UPDATE public.cloud_authorizations SET cloud_sync=request.cloud_sync,file_sync=request.file_sync,
        status=CASE WHEN request.cloud_sync THEN 'authorized' ELSE 'revoked' END,
        revoked_at=CASE WHEN request.cloud_sync THEN NULL ELSE coalesce(revoked_at,now()) END,
        valid_until=request.valid_until,updated_at=now() WHERE user_id=request.bound_user_id;
    END IF;
    IF (previous_request.approved_at IS NULL AND request.approved_at IS NOT NULL)
      OR previous_request.status IS DISTINCT FROM request.status
      OR previous_request.cloud_sync IS DISTINCT FROM request.cloud_sync
      OR previous_request.file_sync IS DISTINCT FROM request.file_sync THEN
      INSERT INTO private.consent_audit(request_id,action,notice_version,verification_method,cloud_sync,file_sync)
        VALUES(request.id,'permissions_changed',request.notice_version,'kws-opt-in-vpc',request.cloud_sync,request.file_sync);
    END IF;
    RETURN to_jsonb(request);
  ELSIF p_action = 'begin_refresh' THEN
    SELECT * INTO request FROM private.parental_consent_requests
      WHERE id=(p_data->>'id')::uuid FOR UPDATE;
    IF NOT FOUND OR request.requires_new_consent OR request.kws_request_id IS NULL
      OR (request.bound_user_id IS NULL AND request.expires_at<=now())
      OR request.refresh_lease_until>now()
      OR (coalesce(p_data->'force','false'::jsonb)<>'true'::jsonb AND (
        (request.status='authorized' AND request.valid_until>now()+interval '1 minute')
        OR request.last_checked_at>now()-interval '30 seconds')) THEN
      RETURN NULL;
    END IF;
    UPDATE private.parental_consent_requests SET refresh_lease_until=now()+interval '30 seconds',
      revision=revision+1 WHERE id=request.id RETURNING * INTO request;
    RETURN to_jsonb(request);
  ELSIF p_action = 'adult' THEN
    actor := (p_data->>'userId')::uuid;
    IF p_data->>'noticeVersion' IS DISTINCT FROM '2026-11-12-v3'
      OR p_data->>'age' IS NULL OR p_data->>'country' IS NULL
      OR (p_data->>'age')::integer < 18 OR (p_data->>'age')::integer > 120
      OR p_data->>'country' !~ '^[A-Z]{2}$'
      OR p_data->'termsAccepted' IS DISTINCT FROM 'true'::jsonb
      OR p_data->'privacyAcknowledged' IS DISTINCT FROM 'true'::jsonb THEN
      RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Current adult acknowledgement required';
    END IF;
    SELECT * INTO profile FROM public.cloud_authorizations WHERE user_id=actor FOR UPDATE;
    IF FOUND AND profile.account_kind='parent_managed' THEN
      SELECT * INTO request FROM private.parental_consent_requests WHERE bound_user_id=actor FOR UPDATE;
      IF NOT FOUND OR request.age+extract(year FROM age(now(),request.created_at))<18 THEN
        RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Parent authorization required for this account';
      END IF;
      UPDATE private.parental_consent_requests SET bound_user_id=NULL,parent_can_manage=false,
        requires_new_consent=true,status='revoked',expires_at=now() WHERE id=request.id;
      UPDATE public.cloud_authorizations SET account_kind='adult',status='authorized',cloud_sync=true,
        file_sync=true,valid_until=NULL,revoked_at=NULL,updated_at=now() WHERE user_id=actor;
    ELSIF FOUND AND profile.status='revoked' THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cloud access has been withdrawn';
    END IF;
    INSERT INTO public.cloud_authorizations(user_id,account_kind,country,notice_version,status,cloud_sync,file_sync)
      VALUES(actor,'adult',p_data->>'country','2026-11-12-v3','authorized',true,true)
      ON CONFLICT(user_id) DO UPDATE SET notice_version=excluded.notice_version,updated_at=now()
      RETURNING * INTO profile;
    RETURN to_jsonb(profile);
  ELSIF p_action = 'bind' THEN
    actor := (p_data->>'userId')::uuid;
    SELECT * INTO request FROM private.parental_consent_requests
      WHERE claim_hash=p_data->>'claimHash' FOR UPDATE;
    IF NOT FOUND OR request.status<>'authorized' OR NOT request.cloud_sync
      OR request.approved_at IS NULL OR request.valid_until IS NULL OR request.valid_until <= now()
      OR request.notice_version<>'2026-11-12-v3' OR request.requires_new_consent
      OR (request.bound_user_id IS NULL AND request.expires_at <= now())
      OR (request.bound_user_id IS NOT NULL AND request.bound_user_id<>actor) THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Verified parental authorization required';
    END IF;
    IF request.bound_user_id IS NULL THEN
      SELECT * INTO profile FROM public.cloud_authorizations WHERE user_id=actor FOR UPDATE;
      IF FOUND AND profile.account_kind='parent_managed' AND profile.status='revoked' THEN
        SELECT * INTO previous_request FROM private.parental_consent_requests
          WHERE bound_user_id=actor FOR UPDATE;
        IF NOT FOUND OR request.age>previous_request.age+
          extract(year FROM age(now(),previous_request.created_at)) THEN
          RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Known account age cannot be increased by a new consent request';
        END IF;
        UPDATE private.parental_consent_requests SET bound_user_id=NULL,parent_can_manage=false,
          expires_at=now() WHERE bound_user_id=actor;
      ELSIF FOUND OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=actor AND is_anonymous=true)
        OR EXISTS(SELECT 1 FROM public.clipboard WHERE user_id=actor)
        OR EXISTS(SELECT 1 FROM public.devices WHERE user_id=actor) THEN
        RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Use a new parent-managed account';
      END IF;
      UPDATE private.parental_consent_requests SET bound_user_id=actor,revision=revision+1 WHERE id=request.id;
      INSERT INTO private.consent_audit(request_id,action,notice_version,verification_method,cloud_sync,file_sync)
        VALUES(request.id,'account_bound',request.notice_version,'kws-opt-in-vpc',request.cloud_sync,request.file_sync);
    END IF;
    INSERT INTO public.cloud_authorizations(user_id,account_kind,country,notice_version,status,cloud_sync,file_sync,valid_until)
      VALUES(actor,'parent_managed',request.country,request.notice_version,'authorized',request.cloud_sync,request.file_sync,request.valid_until)
      ON CONFLICT(user_id) DO UPDATE SET cloud_sync=excluded.cloud_sync,file_sync=excluded.file_sync,
        country=excluded.country,notice_version=excluded.notice_version,
        revoked_at=NULL,
        status=excluded.status,valid_until=excluded.valid_until,updated_at=now() RETURNING * INTO profile;
    RETURN to_jsonb(profile);
  ELSIF p_action = 'profile' THEN
    SELECT * INTO profile FROM public.cloud_authorizations WHERE user_id=(p_data->>'userId')::uuid;
    RETURN CASE WHEN FOUND THEN to_jsonb(profile) ELSE NULL END;
  ELSIF p_action = 'event' THEN
    subject := (p_data->>'id')::uuid;
    SELECT * INTO request FROM private.parental_consent_requests WHERE id=subject FOR UPDATE;
    IF NOT FOUND THEN RETURN jsonb_build_object('ignored',true); END IF;
    IF (p_data->>'eventAt')::timestamptz < request.last_event_at THEN
      RETURN jsonb_build_object('ignored',true);
    END IF;
    IF p_data ? 'kwsRequestId' AND request.kws_request_id IS DISTINCT FROM p_data->>'kwsRequestId' THEN
      IF request.status='initiating' THEN RAISE EXCEPTION 'Consent request is initializing'; END IF;
      RETURN jsonb_build_object('ignored',true);
    END IF;
    INSERT INTO private.consent_events(event_hash,request_id,event_name,event_at)
      VALUES(p_data->>'hash',subject,p_data->>'name',(p_data->>'eventAt')::timestamptz)
      ON CONFLICT(event_hash) DO NOTHING;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed=0 AND (SELECT processed FROM private.consent_events WHERE event_hash=p_data->>'hash') THEN
      RETURN jsonb_build_object('ignored',true);
    END IF;
    IF changed>0 THEN
      UPDATE private.parental_consent_requests SET cloud_sync=false,file_sync=false,
        status=CASE WHEN p_data->'permanent'='true'::jsonb THEN 'revoked' ELSE 'pending' END,
        valid_until=now(),last_event_at=(p_data->>'eventAt')::timestamptz,
        requires_new_consent=CASE WHEN p_data->'permanent'='true'::jsonb THEN true
          WHEN p_data->'grantChange'='true'::jsonb THEN false ELSE requires_new_consent END,
        parent_can_manage=CASE WHEN p_data->'unlinkParent'='true'::jsonb THEN false ELSE parent_can_manage END,
        file_revoked_at=CASE WHEN p_data->'fileDenied'='true'::jsonb
          THEN greatest(file_revoked_at,(p_data->>'eventAt')::timestamptz) ELSE file_revoked_at END,
        revision=revision+1
        WHERE id=subject RETURNING * INTO request;
      UPDATE public.cloud_authorizations SET cloud_sync=false,file_sync=false,status='revoked',
        valid_until=now(),revoked_at=coalesce(revoked_at,now()),updated_at=now() WHERE user_id=request.bound_user_id;
      -- Stop waking a revoked account, including service-role push paths.
      UPDATE public.devices SET fcm_token=NULL,wns_channel_uri=NULL
        WHERE user_id=request.bound_user_id;
      INSERT INTO private.consent_audit(request_id,action,notice_version,cloud_sync,file_sync)
        VALUES(subject,p_data->>'name',request.notice_version,false,false);
    END IF;
    IF p_data->'permanent'='true'::jsonb THEN
      UPDATE private.consent_events SET processed=true WHERE event_hash=p_data->>'hash';
    END IF;
    RETURN to_jsonb(request);
  ELSIF p_action = 'event_done' THEN
    UPDATE private.consent_events SET processed=true WHERE event_hash=p_data->>'hash';
    RETURN '{}'::jsonb;
  ELSIF p_action = 'parent_list' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('id',id,'age',age,'country',country,
      'status',status,'cloudSync',cloud_sync,'fileSync',file_sync,'createdAt',created_at,
      'accountLabel','GhostCopy account ' || right(id::text,6),'hasAccount',bound_user_id IS NOT NULL)), '[]')
      INTO result FROM private.parental_consent_requests
      WHERE parent_hash=p_data->>'parentHash' AND approved_at IS NOT NULL AND parent_can_manage
        AND age+extract(year FROM age(now(),created_at))<18;
    RETURN result;
  ELSIF p_action = 'parent_lookup' THEN
    SELECT * INTO request FROM private.parental_consent_requests
      WHERE id=(p_data->>'id')::uuid AND parent_hash=p_data->>'parentHash' AND approved_at IS NOT NULL
        AND parent_can_manage AND age+extract(year FROM age(now(),created_at))<18;
    RETURN CASE WHEN FOUND THEN to_jsonb(request) ELSE NULL END;
  ELSIF p_action = 'revoke' THEN
    UPDATE private.parental_consent_requests SET status='revoked',cloud_sync=false,file_sync=false,
      requires_new_consent=true,valid_until=now(),last_event_at=now(),revision=revision+1
      WHERE id=(p_data->>'id')::uuid RETURNING * INTO request;
    IF NOT FOUND THEN RETURN NULL; END IF;
    UPDATE public.cloud_authorizations SET status='revoked',cloud_sync=false,file_sync=false,
      valid_until=now(),revoked_at=coalesce(revoked_at,now()),updated_at=now() WHERE user_id=request.bound_user_id;
    UPDATE public.devices SET fcm_token=NULL,wns_channel_uri=NULL WHERE user_id=request.bound_user_id;
    INSERT INTO private.consent_audit(request_id,action,notice_version)
      VALUES(request.id,'parent_withdrew_consent',request.notice_version);
    RETURN to_jsonb(request);
  ELSIF p_action = 'remove_request' THEN
    DELETE FROM private.parental_consent_requests WHERE id=(p_data->>'id')::uuid;
    RETURN '{}'::jsonb;
  ELSIF p_action = 'cleanup' THEN
    -- Known parent-managed accounts only. Refreshing a live permission lease
    -- updates updated_at; withdrawal has a shorter, explicit retention period.
    DELETE FROM auth.users WHERE id IN (
      SELECT user_id FROM public.cloud_authorizations WHERE account_kind='parent_managed'
        AND (updated_at<now()-interval '90 days'
          OR (status='revoked' AND coalesce(revoked_at,updated_at)<now()-interval '30 days'))
      ORDER BY updated_at LIMIT 100 FOR UPDATE SKIP LOCKED);
    DELETE FROM private.parental_consent_requests WHERE bound_user_id IS NULL AND expires_at<=now();
    DELETE FROM private.consent_rate_limits WHERE window_start<now()-interval '2 hours';
    DELETE FROM private.consent_events WHERE received_at<now()-interval '30 days';
    DELETE FROM private.consent_audit WHERE recorded_at<now()-interval '30 days'
      AND NOT EXISTS(SELECT 1 FROM private.parental_consent_requests r WHERE r.id=request_id);
    WITH claimed AS (SELECT subject_id FROM private.kws_deletion_queue
      WHERE next_attempt_at<=now() AND (lease_until IS NULL OR lease_until<=now())
      ORDER BY next_attempt_at LIMIT 50 FOR UPDATE SKIP LOCKED)
    , updated AS (UPDATE private.kws_deletion_queue q SET attempts=q.attempts+1,
      lease_until=now()+interval '5 minutes',next_attempt_at=now()+interval '5 minutes'
      FROM claimed c WHERE q.subject_id=c.subject_id RETURNING q.subject_id)
    SELECT coalesce(jsonb_agg(subject_id),'[]') INTO result FROM updated;
    RETURN result;
  ELSIF p_action = 'deletion_done' THEN
    DELETE FROM private.kws_deletion_queue WHERE subject_id=(p_data->>'id')::uuid;
    RETURN '{}'::jsonb;
  END IF;
  RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported consent operation';
END $$;
REVOKE ALL ON FUNCTION public.consent_service(text,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.consent_service(text,jsonb) TO service_role;
