


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'Dropped 16 duplicate indexes on clipboard partitions to improve write performance and reduce storage overhead.';



CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."content_type_enum" AS ENUM (
    'text',
    'html',
    'markdown',
    'image_png',
    'image_jpeg',
    'image_gif',
    'file_pdf',
    'file_doc',
    'file_docx',
    'file_txt',
    'file_zip',
    'file_tar',
    'file_gz',
    'file_mp4',
    'file_mp3',
    'file_wav',
    'file_other'
);


ALTER TYPE "public"."content_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."device_type_enum" AS ENUM (
    'windows',
    'macos',
    'android',
    'ios',
    'linux'
);


ALTER TYPE "public"."device_type_enum" OWNER TO "postgres";


CREATE TYPE "public"."rich_text_format_enum" AS ENUM (
    'html',
    'markdown'
);


ALTER TYPE "public"."rich_text_format_enum" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."broadcast_clipboard_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'realtime'
    AS $$
DECLARE
  topic text;
BEGIN
  topic := 'clipboard:' || COALESCE(NEW.user_id, OLD.user_id)::text;

  PERFORM realtime.broadcast_changes(
    topic,
    TG_OP,
    TG_OP,
    TG_TABLE_NAME,
    TG_TABLE_SCHEMA,
    NEW,
    OLD
  );

  RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."broadcast_clipboard_changes"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."broadcast_clipboard_changes"() IS 'Broadcasts clipboard INSERT/UPDATE/DELETE events to per-user private Realtime topics.';



CREATE OR REPLACE FUNCTION "public"."check_clipboard_rate_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  current_count int;
  window_start_time timestamptz;
  max_inserts_per_minute int := 10; -- Max 10 clips per minute per user
  window_duration interval := INTERVAL '1 minute';
BEGIN
  -- Get current rate limit record for this user
  SELECT insert_count, window_start
  INTO current_count, window_start_time
  FROM user_rate_limit
  WHERE user_id = NEW.user_id;

  -- Initialize if user has no rate limit record yet
  IF NOT FOUND THEN
    INSERT INTO user_rate_limit (user_id, insert_count, window_start)
    VALUES (NEW.user_id, 1, NOW())
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
  END IF;

  -- Check if window has expired (rolling 1-minute window)
  IF NOW() - window_start_time > window_duration THEN
    -- Reset window
    UPDATE user_rate_limit
    SET insert_count = 1,
        window_start = NOW(),
        updated_at = NOW()
    WHERE user_id = NEW.user_id;

    RETURN NEW;
  END IF;

  -- Check if user has exceeded rate limit
  IF current_count >= max_inserts_per_minute THEN
    -- Log rate limit violation
    RAISE WARNING 'Rate limit exceeded for user %: % inserts in % seconds',
      NEW.user_id,
      current_count,
      EXTRACT(EPOCH FROM (NOW() - window_start_time));

    -- Block the insert with a clear error message
    RAISE EXCEPTION 'Rate limit exceeded: Maximum % clipboard inserts per minute allowed. Please wait % seconds before trying again.',
      max_inserts_per_minute,
      CEIL(EXTRACT(EPOCH FROM (window_start_time + window_duration - NOW())))
      USING ERRCODE = '42501', -- insufficient_privilege
            HINT = 'Rate limit resets in a rolling 1-minute window';
  END IF;

  -- Increment count within current window
  UPDATE user_rate_limit
  SET insert_count = insert_count + 1,
      updated_at = NOW()
  WHERE user_id = NEW.user_id;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_clipboard_rate_limit"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."check_clipboard_rate_limit"() IS 'Enforces database-level rate limiting on clipboard inserts.
Prevents spam attacks that bypass client-side rate limiting.
Max: 10 inserts per minute per user (rolling window).
Returns clear error message with wait time when limit exceeded.';



CREATE OR REPLACE FUNCTION "public"."check_devices_rate_limit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  device_count int;
  max_devices int := 10; -- Allow up to 10 devices per user
BEGIN
  -- Count existing devices for this user
  SELECT COUNT(*) INTO device_count
  FROM devices
  WHERE user_id = NEW.user_id;

  -- Check if user has reached the limit
  IF device_count >= max_devices THEN
    RAISE EXCEPTION 'Maximum % devices per user exceeded. Please delete unused devices before registering new ones.', max_devices
      USING ERRCODE = '42501', -- insufficient_privilege
            HINT = 'You can have up to 10 devices registered at once';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_devices_rate_limit"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."check_devices_rate_limit"() IS 'Enforces device count limit (max 10 per user).
Prevents spam device registrations.
Users must delete old devices before registering new ones if at limit.';



CREATE OR REPLACE FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer DEFAULT 15) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$                                                                                                                                                                                     
  declare                                                                                                                                                                                   
    v_to_delete record;                                                                                                                                                                     
  begin                                                                                                                                                                                     
    if auth.uid() is distinct from p_user_id then                                                                                                                                           
      raise exception 'Unauthorized: Cannot delete clipboard items for other users';                                                                                                        
    end if;                                                                                                                                                                                 
                                                                                                                                                                                            
    if p_keep_count < 0 then                                                                                                                                                                
      raise exception 'Invalid parameter: p_keep_count must be >= 0';                                                                                                                       
    end if;                                                                                                                                                                                 
                                                                                                                                                                                            
    for v_to_delete in                                                                                                                                                                      
      select id, storage_path                                                                                                                                                               
      from clipboard                                                                                                                                                                        
      where user_id = p_user_id                                                                                                                                                             
      order by created_at desc                                                                                                                                                              
      offset p_keep_count                                                                                                                                                                   
    loop                                                                                                                                                                                    
      if v_to_delete.storage_path is not null then                                                                                                                                          
        begin                                                                                                                                                                               
          perform storage.delete_object('clipboard-files', v_to_delete.storage_path);                                                                                                       
        exception when others then                                                                                                                                                          
          raise warning 'Failed to delete storage file %: %', v_to_delete.storage_path, sqlerrm;                                                                                            
        end;                                                                                                                                                                                
      end if;                                                                                                                                                                               
                                                                                                                                                                                            
      delete from clipboard where id = v_to_delete.id;                                                                                                                                      
    end loop;                                                                                                                                                                               
  end;                                                                                                                                                                                      
  $$;


ALTER FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) IS 'Deletes old clipboard items. SECURITY: Simple auth check - users can only delete their own items (auth.uid() = p_user_id).';



CREATE OR REPLACE FUNCTION "public"."cleanup_old_clipboard_items_deep"() RETURNS TABLE("deleted_count" bigint, "processed_users" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_deleted      bigint := 0;
  v_users        bigint := 0;
  batch_deleted  bigint;
BEGIN
  -- Count affected users once (cheap aggregate with HAVING, uses the composite index).
  SELECT COUNT(*) INTO v_users
  FROM (
    SELECT 1 FROM clipboard GROUP BY user_id HAVING COUNT(*) > 20
  ) excess;

  -- Delete in batches of 5000 to limit lock duration and WAL pressure.
  -- Each iteration re-evaluates the window function on the remaining rows.
  -- Converges quickly: after batch N the table has fewer rows, so the
  -- window scan is cheaper each time.
  LOOP
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn
      FROM clipboard
    )
    DELETE FROM clipboard
    WHERE id IN (SELECT id FROM ranked WHERE rn > 20 LIMIT 5000);

    GET DIAGNOSTICS batch_deleted = ROW_COUNT;
    v_deleted := v_deleted + batch_deleted;

    EXIT WHEN batch_deleted = 0;

    -- Yield to concurrent operations between batches
    PERFORM pg_sleep(0.05);
  END LOOP;

  deleted_count   := v_deleted;
  processed_users := v_users;
  RETURN NEXT;

  RAISE NOTICE 'Cleanup: % clips deleted for % users', v_deleted, v_users;
END;
$$;


ALTER FUNCTION "public"."cleanup_old_clipboard_items_deep"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cleanup_old_clipboard_items_deep"() IS 'Batched set-based cleanup using ROW_NUMBER() window function.
Deletes in batches of 5000 with 50ms yields between batches to avoid
prolonged lock-holding. Leverages idx_clipboard_user_id_created_at.
Keeps the 20 most recent clips per user. Called daily by pg_cron job.';



CREATE OR REPLACE FUNCTION "public"."cleanup_stale_rate_limits"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  -- Delete rate limit records older than 1 day (no activity)
  DELETE FROM public.user_rate_limit
  WHERE updated_at < NOW() - INTERVAL '1 day';

  RAISE NOTICE 'Cleaned up stale rate limit records';
END;
$$;


ALTER FUNCTION "public"."cleanup_stale_rate_limits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_storage_on_clipboard_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault'
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
$$;


ALTER FUNCTION "public"."cleanup_storage_on_clipboard_delete"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cleanup_storage_on_clipboard_delete"() IS 'Auto-deletes files from Cloudflare R2 when clipboard items are deleted.
Calls storage-presign edge function with delete action via pg_net.
Securely retrieves service role key from Supabase Vault.';



CREATE OR REPLACE FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
DECLARE
  caller_user_id uuid := auth.uid();
BEGIN
  IF caller_user_id IS NULL
      OR caller_user_id IS DISTINCT FROM p_user_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Unauthorized: cannot delete data for another user';
  END IF;

  DELETE FROM public.clipboard
  WHERE user_id = p_user_id;

  DELETE FROM public.devices
  WHERE user_id = p_user_id;

  DELETE FROM public.mobile_link_tokens
  WHERE user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") IS 'Deletes all data for a user. SECURITY: Simple auth check - users can only delete their own data (auth.uid() = p_user_id).';



CREATE OR REPLACE FUNCTION "public"."configure_storage_cleanup_settings"("p_supabase_url" "text", "p_service_role_key" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Validate inputs
  IF p_supabase_url = '' OR p_service_role_key = '' THEN
    RAISE EXCEPTION 'Both supabase_url and service_role_key must be non-empty';
  END IF;

  IF NOT p_supabase_url LIKE 'https://%' THEN
    RAISE EXCEPTION 'supabase_url must start with https://';
  END IF;

  -- Note: This function is deprecated - we now use existing vault secrets
  -- (fcm_service_role_key and supabase_api_url)
  RAISE NOTICE '⚠️  This function is deprecated!';
  RAISE NOTICE '';
  RAISE NOTICE 'Storage cleanup now uses existing vault secrets:';
  RAISE NOTICE '  - fcm_service_role_key (your service role key)';
  RAISE NOTICE '  - supabase_api_url (your project URL)';
  RAISE NOTICE '';
  RAISE NOTICE 'No action needed - your vault is already configured!';
  RAISE NOTICE '';
END;
$$;


ALTER FUNCTION "public"."configure_storage_cleanup_settings"("p_supabase_url" "text", "p_service_role_key" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."configure_storage_cleanup_settings"("p_supabase_url" "text", "p_service_role_key" "text") IS 'DEPRECATED: Helper function to configure storage cleanup settings.
No longer needed - storage cleanup uses existing vault secrets (fcm_service_role_key, supabase_api_url).
Kept for backwards compatibility with explicit search_path for security.';



CREATE OR REPLACE FUNCTION "public"."consume_mobile_link_token"("p_token_hash" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
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
$$;


ALTER FUNCTION "public"."consume_mobile_link_token"("p_token_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'vault'
    AS $$
DECLARE
  has_mobile_targets boolean;
  supabase_url text;
  service_role_key text;
BEGIN
  has_mobile_targets := (
    NEW.target_device_type IS NULL
    OR NEW.target_device_type::text[] @> ARRAY['ios']
    OR NEW.target_device_type::text[] @> ARRAY['android']
  );

  IF NOT has_mobile_targets THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT decrypted_secret
    INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'supabase_api_url'
    LIMIT 1;

    SELECT decrypted_secret
    INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'fcm_service_role_key'
    LIMIT 1;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING '[Clipboard Notify] Unable to access Vault secrets: %', SQLERRM;
  END;

  IF COALESCE(supabase_url, '') = '' THEN
    supabase_url := NULLIF(current_setting('app.settings.supabase_url', true), '');
  END IF;

  IF COALESCE(service_role_key, '') = '' THEN
    service_role_key := NULLIF(current_setting('app.settings.service_role_key', true), '');
  END IF;

  IF COALESCE(supabase_url, '') = '' OR COALESCE(service_role_key, '') = '' THEN
    RAISE WARNING '[Clipboard Notify] Missing Supabase URL or service role key for clipboard_id=%', NEW.id;
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := supabase_url || '/functions/v1/send-clipboard-notification',
    body := jsonb_build_object(
      'record', row_to_json(NEW),
      'type', 'INSERT'
    ),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || service_role_key,
      'Content-Type', 'application/json'
    ),
    timeout_milliseconds := 30000
  );

  RAISE LOG '[Clipboard Notify] Invoked edge function for clipboard_id=%', NEW.id;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"() IS 'Smart trigger that only calls FCM edge function if mobile devices are targeted.
Desktop-only sends skip the edge function call entirely, saving invocation costs.
Search path is now immutably set to public (fixes security advisory).';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "key" "text" NOT NULL,
    "enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "updated_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    "value" "text"
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


COMMENT ON TABLE "public"."app_config" IS 'App configuration readable by all authenticated users. For feature flags like hybrid_mode_enabled.';



COMMENT ON COLUMN "public"."app_config"."key" IS 'Unique configuration key (e.g., hybrid_mode_enabled)';



COMMENT ON COLUMN "public"."app_config"."enabled" IS 'Boolean flag for enabling/disabling features';



CREATE TABLE IF NOT EXISTS "public"."clipboard" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "device_name" "text",
    "device_type" "public"."device_type_enum" NOT NULL,
    "target_device_type" "public"."device_type_enum"[],
    "is_public" boolean DEFAULT false NOT NULL,
    "is_encrypted" boolean DEFAULT false NOT NULL,
    "encryption_version" integer,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "expires_at" timestamp with time zone,
    "content_type" "public"."content_type_enum" DEFAULT 'text'::"public"."content_type_enum" NOT NULL,
    "storage_path" "text",
    "file_size_bytes" bigint,
    "mime_type" "text",
    "metadata" "jsonb",
    "rich_text_format" "public"."rich_text_format_enum",
    CONSTRAINT "check_file_size_limit" CHECK ((("file_size_bytes" IS NULL) OR ("file_size_bytes" <= 10485760))),
    CONSTRAINT "check_storage_for_files" CHECK (((("content_type" = ANY (ARRAY['text'::"public"."content_type_enum", 'html'::"public"."content_type_enum", 'markdown'::"public"."content_type_enum"])) AND ("storage_path" IS NULL)) OR (("content_type" <> ALL (ARRAY['text'::"public"."content_type_enum", 'html'::"public"."content_type_enum", 'markdown'::"public"."content_type_enum"])) AND ("storage_path" IS NOT NULL)))),
    CONSTRAINT "clipboard_storage_path_owned_by_user" CHECK ((("storage_path" IS NULL) OR ("storage_path" ~~ (("user_id")::"text" || '/%'::"text")))),
    CONSTRAINT "enforce_private_only" CHECK (("is_public" = false))
);


ALTER TABLE "public"."clipboard" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clipboard"."content_type" IS 'Type of clipboard content (text, html, markdown, images, or any file type under 10MB)';



COMMENT ON COLUMN "public"."clipboard"."storage_path" IS 'Supabase Storage path for images/files. NULL for text content. Format: user_id/clip_id/filename';



COMMENT ON COLUMN "public"."clipboard"."file_size_bytes" IS 'File size in bytes for upload progress and quota tracking';



COMMENT ON COLUMN "public"."clipboard"."mime_type" IS 'Original MIME type from clipboard (e.g., image/png, text/html)';



COMMENT ON COLUMN "public"."clipboard"."metadata" IS 'JSON metadata: {width, height, thumbnail_url, original_filename}. original_filename is preserved for all file types.';



COMMENT ON COLUMN "public"."clipboard"."rich_text_format" IS 'Format for rich text content (html or markdown)';



ALTER TABLE "public"."clipboard" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."clipboard_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."devices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "device_type" "public"."device_type_enum" NOT NULL,
    "device_name" "text",
    "fcm_token" "text",
    "last_active" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    CONSTRAINT "devices_device_name_check" CHECK ((("device_name" IS NULL) OR ("length"("device_name") <= 255))),
    CONSTRAINT "devices_fcm_token_check" CHECK ((("fcm_token" IS NULL) OR (("length"("fcm_token") > 0) AND ("length"("fcm_token") <= 4096))))
);


ALTER TABLE "public"."devices" OWNER TO "postgres";


COMMENT ON TABLE "public"."devices" IS 'Stores device registration tokens for push notifications. Supports both authenticated and anonymous users.';



COMMENT ON COLUMN "public"."devices"."device_type" IS 'Device platform type';



COMMENT ON COLUMN "public"."devices"."fcm_token" IS 'FCM token for push notifications. NULL for desktop devices (use Realtime), required for mobile (Android/iOS)';



COMMENT ON COLUMN "public"."devices"."last_active" IS 'Last time this device was active, used for cleanup of stale tokens';



CREATE TABLE IF NOT EXISTS "public"."mobile_link_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "pin_hash" "text",
    CONSTRAINT "mobile_link_tokens_pin_hash_required" CHECK ((("pin_hash" IS NOT NULL) AND ("pin_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "mobile_link_tokens_token_sha256" CHECK (("token" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "public"."mobile_link_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_rate_limit" (
    "user_id" "uuid" NOT NULL,
    "insert_count" integer DEFAULT 0 NOT NULL,
    "window_start" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_rate_limit" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_rate_limit" IS 'Tracks clipboard insert rate per user to prevent spam attacks.
Rolling 1-minute window with max 10 inserts per minute.
Cleaned up automatically when user is deleted (CASCADE).';



ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."clipboard"
    ADD CONSTRAINT "clipboard_new_pkey1" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_user_type_name_unique" UNIQUE ("user_id", "device_type", "device_name");



ALTER TABLE "public"."mobile_link_tokens"
    ADD CONSTRAINT "mobile_link_tokens_max_ttl" CHECK (("expires_at" <= ("created_at" + '00:10:00'::interval))) NOT VALID;



ALTER TABLE ONLY "public"."mobile_link_tokens"
    ADD CONSTRAINT "mobile_link_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mobile_link_tokens"
    ADD CONSTRAINT "mobile_link_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "unique_user_token" UNIQUE ("user_id", "fcm_token");



ALTER TABLE ONLY "public"."user_rate_limit"
    ADD CONSTRAINT "user_rate_limit_pkey" PRIMARY KEY ("user_id");



CREATE UNIQUE INDEX "devices_fcm_token_global_unique" ON "public"."devices" USING "btree" ("fcm_token") WHERE ("fcm_token" IS NOT NULL);



CREATE INDEX "idx_clipboard_content_type" ON "public"."clipboard" USING "btree" ("user_id", "content_type", "created_at" DESC);



CREATE INDEX "idx_clipboard_encryption_version" ON "public"."clipboard" USING "btree" ("encryption_version") WHERE ("encryption_version" IS NOT NULL);



CREATE INDEX "idx_clipboard_search" ON "public"."clipboard" USING "gin" ("to_tsvector"('"english"'::"regconfig", "content"));



CREATE INDEX "idx_clipboard_storage_path" ON "public"."clipboard" USING "btree" ("storage_path") WHERE ("storage_path" IS NOT NULL);



CREATE INDEX "idx_clipboard_target_device_type" ON "public"."clipboard" USING "btree" ("target_device_type") WHERE ("target_device_type" IS NOT NULL);



CREATE INDEX "idx_clipboard_user_id_created_at" ON "public"."clipboard" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_clipboard_user_id_id" ON "public"."clipboard" USING "btree" ("user_id", "id" DESC);



CREATE INDEX "idx_clipboard_user_id_is_encrypted" ON "public"."clipboard" USING "btree" ("user_id", "is_encrypted");



CREATE INDEX "idx_devices_fcm_token" ON "public"."devices" USING "btree" ("user_id", "device_type") WHERE ("fcm_token" IS NOT NULL);



CREATE INDEX "idx_devices_last_active" ON "public"."devices" USING "btree" ("last_active" DESC);



CREATE INDEX "idx_devices_user_device_type" ON "public"."devices" USING "btree" ("user_id", "device_type");



CREATE INDEX "idx_mobile_link_tokens_expires_at" ON "public"."mobile_link_tokens" USING "btree" ("expires_at");



CREATE INDEX "idx_mobile_link_tokens_user_id" ON "public"."mobile_link_tokens" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "cleanup_storage_after_clipboard_delete" AFTER DELETE ON "public"."clipboard" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_storage_on_clipboard_delete"();



CREATE OR REPLACE TRIGGER "clipboard_notify_mobile_on_insert" AFTER INSERT ON "public"."clipboard" FOR EACH ROW EXECUTE FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"();



COMMENT ON TRIGGER "clipboard_notify_mobile_on_insert" ON "public"."clipboard" IS 'Triggers send-clipboard-notification edge function only for mobile-targeted clips.
Filters desktop-only sends at DB level to optimize costs (0 invocations).
Fires AFTER INSERT so clipboard_id is generated.';



CREATE OR REPLACE TRIGGER "clipboard_rate_limit_check" BEFORE INSERT ON "public"."clipboard" FOR EACH ROW EXECUTE FUNCTION "public"."check_clipboard_rate_limit"();



COMMENT ON TRIGGER "clipboard_rate_limit_check" ON "public"."clipboard" IS 'Blocks clipboard inserts that exceed rate limit (10/min per user).
Runs BEFORE INSERT to prevent spam from hitting database.
Part of defense-in-depth security strategy.';



CREATE OR REPLACE TRIGGER "devices_rate_limit_check" BEFORE INSERT ON "public"."devices" FOR EACH ROW EXECUTE FUNCTION "public"."check_devices_rate_limit"();



COMMENT ON TRIGGER "devices_rate_limit_check" ON "public"."devices" IS 'Blocks device registration if user already has 10 devices.
Runs BEFORE INSERT to prevent spam.
Generous limit allows multiple platforms (Windows, macOS, Android, iOS, Linux, etc.).';



ALTER TABLE ONLY "public"."clipboard"
    ADD CONSTRAINT "clipboard_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."devices"
    ADD CONSTRAINT "devices_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mobile_link_tokens"
    ADD CONSTRAINT "mobile_link_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_rate_limit"
    ADD CONSTRAINT "user_rate_limit_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Users can create their own tokens" ON "public"."mobile_link_tokens" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "authenticated_read_app_config" ON "public"."app_config" FOR SELECT USING ((( SELECT "auth"."role"() AS "role") = ANY (ARRAY['authenticated'::"text", 'anon'::"text"])));



ALTER TABLE "public"."clipboard" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mobile_link_tokens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_role_only" ON "public"."user_rate_limit" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_role_update_app_config" ON "public"."app_config" FOR UPDATE USING ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text"));



CREATE POLICY "service_role_write_app_config" ON "public"."app_config" FOR INSERT WITH CHECK ((( SELECT "auth"."role"() AS "role") = 'service_role'::"text"));



ALTER TABLE "public"."user_rate_limit" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users_delete_own_clipboard" ON "public"."clipboard" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_delete_own_devices" ON "public"."devices" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_delete_own_mobile_link_tokens" ON "public"."mobile_link_tokens" FOR DELETE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_insert_own_clipboard" ON "public"."clipboard" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_insert_own_devices" ON "public"."devices" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_update_own_clipboard" ON "public"."clipboard" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_update_own_devices" ON "public"."devices" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_view_own_clipboard_only" ON "public"."clipboard" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "users_view_own_devices" ON "public"."devices" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."clipboard";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."devices";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";















































































































































































































REVOKE ALL ON FUNCTION "public"."broadcast_clipboard_changes"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."broadcast_clipboard_changes"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_clipboard_rate_limit"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_clipboard_rate_limit"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_devices_rate_limit"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_devices_rate_limit"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_old_clipboard_items_deep"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_old_clipboard_items_deep"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_stale_rate_limits"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_stale_rate_limits"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_storage_on_clipboard_delete"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_storage_on_clipboard_delete"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."cleanup_user_data"("p_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."configure_storage_cleanup_settings"("p_supabase_url" "text", "p_service_role_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."configure_storage_cleanup_settings"("p_supabase_url" "text", "p_service_role_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."consume_mobile_link_token"("p_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."consume_mobile_link_token"("p_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_mobile_devices_on_clipboard_insert"() TO "service_role";






























GRANT SELECT ON TABLE "public"."app_config" TO "anon";
GRANT SELECT ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";



GRANT ALL ON TABLE "public"."clipboard" TO "service_role";
GRANT SELECT ON TABLE "public"."clipboard" TO "supabase_realtime_admin";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."clipboard" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."clipboard_id_seq" TO "service_role";
GRANT USAGE ON SEQUENCE "public"."clipboard_id_seq" TO "authenticated";



GRANT ALL ON TABLE "public"."devices" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."devices" TO "authenticated";



GRANT INSERT,DELETE,UPDATE ON TABLE "public"."mobile_link_tokens" TO "anon";
GRANT INSERT,DELETE,UPDATE ON TABLE "public"."mobile_link_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."mobile_link_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."user_rate_limit" TO "service_role";






SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION "postgres";
RESET SESSION AUTHORIZATION;



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































