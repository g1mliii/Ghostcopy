import { readFile } from 'node:fs/promises';
export async function setupConsentDatabase(db) {
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY,is_anonymous boolean DEFAULT true,email text,phone text);
    CREATE TABLE auth.identities(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid REFERENCES auth.users ON DELETE CASCADE,provider text,identity_data jsonb);
    CREATE SCHEMA vault; CREATE TABLE vault.decrypted_secrets(name text,decrypted_secret text);
    CREATE SCHEMA net; CREATE FUNCTION net.http_post(url text,headers jsonb,body jsonb,timeout_milliseconds integer) RETURNS bigint LANGUAGE sql AS $$ SELECT 1::bigint; $$;
    CREATE SCHEMA cron; CREATE FUNCTION cron.schedule(text,text,text) RETURNS bigint LANGUAGE sql AS $$ SELECT 1::bigint; $$;
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid;
    $$;
    GRANT USAGE ON SCHEMA auth TO authenticated, anon, service_role;
    CREATE TABLE public.clipboard(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
      is_encrypted boolean NOT NULL DEFAULT false, storage_path text, content text);
    CREATE TABLE public.clipboard_test(LIKE public.clipboard INCLUDING ALL);
    CREATE TABLE public.clipboard_p0(LIKE public.clipboard INCLUDING ALL);
    CREATE TABLE public.devices(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
      user_id uuid REFERENCES auth.users ON DELETE CASCADE,fcm_token text,wns_channel_uri text);
    CREATE TABLE public.mobile_link_tokens(token text PRIMARY KEY,
      user_id uuid REFERENCES auth.users ON DELETE CASCADE);
    CREATE TABLE public.clipboard_content(id bigint REFERENCES public.clipboard(id), content text);
    CREATE FUNCTION public.claim_fcm_token(uuid,text) RETURNS boolean LANGUAGE sql AS $$ SELECT true; $$;
    CREATE FUNCTION public.claim_wns_channel(uuid,text) RETURNS boolean LANGUAGE sql AS $$ SELECT true; $$;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
    GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;
    GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;
    DO $$ DECLARE item text; BEGIN
      FOREACH item IN ARRAY ARRAY['clipboard','clipboard_test','clipboard_p0','devices','mobile_link_tokens'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',item);
        EXECUTE format('CREATE POLICY own_rows ON public.%I TO authenticated USING(user_id=auth.uid()) WITH CHECK(user_id=auth.uid())',item);
      END LOOP;
    END $$;
    ALTER TABLE public.clipboard_content ENABLE ROW LEVEL SECURITY;
    CREATE POLICY legacy_content ON public.clipboard_content TO authenticated USING(true) WITH CHECK(true);
  `);
  await db.exec(await readFile(new URL('../../supabase/migrations/20261112220000_cloud_consent_authorization.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../../supabase/migrations/20261112221000_consent_service_operations.sql', import.meta.url), 'utf8'));
  await db.exec(await readFile(new URL('../../supabase/migrations/20261112222000_parent_account_and_cleanup.sql', import.meta.url), 'utf8'));
}
