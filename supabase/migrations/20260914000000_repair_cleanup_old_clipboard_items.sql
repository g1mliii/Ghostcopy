-- Repair cleanup_old_clipboard_items, which cannot currently succeed.
--
-- Found by `supabase db lint --linked`, which reported:
--   public.cleanup_old_clipboard_items
--   ERROR: function storage.delete_object(unknown, text) does not exist
--
-- Two defects, either of which alone makes the function useless:
--
-- 1. Nobody who can call it can pass its own authorization check.
--    EXECUTE is revoked from PUBLIC and granted only to service_role
--    (schema.sql:1252-1253). For service_role, auth.uid() is NULL, so
--    `auth.uid() is distinct from p_user_id` is TRUE for any real uuid and the
--    function raises 'Unauthorized' every time. The one role permitted to run
--    it is the one role guaranteed to fail.
--
-- 2. It calls storage.delete_object(), which does not exist on this database.
--    That call is a leftover from before storage moved to Cloudflare R2. R2
--    deletion is now handled by the cleanup_storage_after_clipboard_delete
--    trigger (schema.sql:878), which fires per row on DELETE FROM clipboard and
--    does the owner-prefix check before calling the storage-presign function.
--    So the call is not only broken, it is redundant: the exception is swallowed
--    by the surrounding EXCEPTION block and turned into a warning, once per
--    file-bearing row.
--
-- Fix: let service_role through the authorization check (it is trusted and is
-- the only grantee), and drop the dead storage call so the trigger is the single
-- path to R2 deletion. The per-user auth check is kept for any future grantee.
--
-- Note the sibling cleanup_old_clipboard_items_deep() already does the right
-- thing: a plain set-based DELETE FROM clipboard, leaving R2 to the trigger.

CREATE OR REPLACE FUNCTION "public"."cleanup_old_clipboard_items"(
  "p_user_id" "uuid",
  "p_keep_count" integer DEFAULT 15
) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  begin
    -- service_role is a trusted backend caller and has no auth.uid(); every
    -- other caller may only clean up its own rows.
    if auth.role() is distinct from 'service_role'
       and auth.uid() is distinct from p_user_id then
      raise exception 'Unauthorized: Cannot delete clipboard items for other users';
    end if;

    if p_keep_count < 0 then
      raise exception 'Invalid parameter: p_keep_count must be >= 0';
    end if;

    -- Set-based, like the _deep variant. The AFTER DELETE trigger
    -- (cleanup_storage_after_clipboard_delete) removes the R2 object for each
    -- row that carries a storage_path, so there is nothing to do here for files.
    delete from clipboard
    where id in (
      select id
      from clipboard
      where user_id = p_user_id
      order by created_at desc
      offset p_keep_count
    );
  end;
  $$;

ALTER FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer)
  OWNER TO "postgres";

COMMENT ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) IS
'Deletes all but the newest p_keep_count clipboard rows for one user.
SECURITY: service_role may act for any user; any other caller may only act on
its own rows (auth.uid() = p_user_id). R2 objects are removed by the
cleanup_storage_after_clipboard_delete trigger, not here.';

REVOKE ALL ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cleanup_old_clipboard_items"("p_user_id" "uuid", "p_keep_count" integer) TO "service_role";
