-- Child identities stay pseudonymous. QR linking's exact synthetic address is
-- allowed; independent email/phone/provider upgrades require an adult account.
CREATE FUNCTION private.guard_parent_managed_identity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE managed boolean; subject uuid;
BEGIN
  subject := (to_jsonb(NEW)->>CASE WHEN TG_TABLE_NAME='users' THEN 'id' ELSE 'user_id' END)::uuid;
  SELECT EXISTS(SELECT 1 FROM public.cloud_authorizations
    WHERE user_id=subject AND account_kind='parent_managed') INTO managed;
  IF NOT managed THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='users' THEN
    IF nullif(NEW.email,'') IS NOT NULL AND NEW.email<>subject::text || '@anon.ghostcopy.app'
      OR nullif(NEW.phone,'') IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Parent-managed accounts cannot add independent credentials';
    END IF;
  ELSIF NEW.provider NOT IN ('anonymous','email') OR
      (NEW.provider='email' AND NEW.identity_data->>'email' IS DISTINCT FROM subject::text || '@anon.ghostcopy.app') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Parent-managed accounts cannot add provider identities';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.guard_parent_managed_identity() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER guard_parent_managed_credentials BEFORE UPDATE OF email,phone ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.guard_parent_managed_identity();
CREATE TRIGGER guard_parent_managed_provider BEFORE INSERT OR UPDATE ON auth.identities
  FOR EACH ROW EXECUTE FUNCTION private.guard_parent_managed_identity();

CREATE FUNCTION public.dispatch_consent_cleanup() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE api_url text; service_key text;
BEGIN
  SELECT decrypted_secret INTO api_url FROM vault.decrypted_secrets WHERE name='supabase_api_url' LIMIT 1;
  SELECT decrypted_secret INTO service_key FROM vault.decrypted_secrets WHERE name='fcm_service_role_key' LIMIT 1;
  IF coalesce(api_url,'')='' OR coalesce(service_key,'')='' THEN
    RAISE EXCEPTION 'Consent cleanup requires existing API URL and service key in Vault';
  END IF;
  PERFORM net.http_post(url:=api_url || '/functions/v1/cloud-consent',
    headers:=jsonb_build_object('Authorization','Bearer ' || service_key,'apikey',service_key,'Content-Type','application/json'),
    body:='{"action":"maintenance"}'::jsonb,timeout_milliseconds:=30000);
END $$;
REVOKE ALL ON FUNCTION public.dispatch_consent_cleanup() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_consent_cleanup() TO service_role;
SELECT cron.schedule('cleanup-parental-consent','*/15 * * * *','SELECT public.dispatch_consent_cleanup()');
