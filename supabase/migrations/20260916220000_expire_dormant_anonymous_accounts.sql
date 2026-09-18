-- cleanup_abandoned_anonymous_users() only removes guests that own nothing.
-- That was deliberate and stays unchanged - it must never race a guest who is
-- mid-setup.
--
-- It leaves a gap. A guest who signs into an existing account keeps their old
-- anonymous id, and the clips made under it stay behind: reachable by nobody,
-- because RLS scopes every read to auth.uid(), and skipped by the cleanup above
-- precisely because clipboard rows exist. The app now warns before this happens
-- (see auth_panel), but every "sign in anyway" still leaves rows nothing
-- reclaims, and the same is true of any guest who simply stops using the app.
--
-- So: expire guests that own data but have shown no sign of life for a long
-- time. Deliberately more cautious than the empty-account rule, because this
-- deletes real content rather than an empty shell:
--
--   * 90 days, not 30. A guest account is the only copy of those clips, and
--     someone returning to a machine after two months should still find them.
--   * Every liveness signal must be cold, not just the auth timestamp. The
--     newest clip and the most recently seen device both count, so an account
--     in active use is never a candidate however its auth rows look.
--
-- Deleting the user is enough to remove everything: clipboard, devices,
-- mobile_link_tokens and user_rate_limit are all ON DELETE CASCADE, and the
-- AFTER DELETE trigger on clipboard queues each stored file for removal, so
-- uploads are reclaimed rather than orphaned in the bucket.
--
-- Bounded like the other cleanups - at most 500 accounts per run, so one call
-- cannot hold a long transaction over auth.users.

CREATE OR REPLACE FUNCTION public.cleanup_dormant_anonymous_users()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  removed integer;
BEGIN
  WITH doomed AS (
    SELECT u.id FROM auth.users u
    WHERE u.is_anonymous
      AND COALESCE(u.last_sign_in_at, u.created_at) < now() - interval '90 days'
      -- No recently refreshed session.
      AND NOT EXISTS (
        SELECT 1 FROM auth.sessions s WHERE s.user_id = u.id
          AND COALESCE(s.updated_at, s.created_at) > now() - interval '90 days'
      )
      -- No clip written in the window. Covers the account that is still in use
      -- but whose auth rows happen to look stale.
      AND NOT EXISTS (
        SELECT 1 FROM public.clipboard c WHERE c.user_id = u.id
          AND c.created_at > now() - interval '90 days'
      )
      -- No device seen in the window. last_active is maintained by the app on
      -- every device registration, so it is the truest liveness signal here.
      AND NOT EXISTS (
        SELECT 1 FROM public.devices d WHERE d.user_id = u.id
          AND GREATEST(d.last_active, d.created_at) > now() - interval '90 days'
      )
      -- Never interrupt a pairing in flight.
      AND NOT EXISTS (
        SELECT 1 FROM public.mobile_link_tokens t WHERE t.user_id = u.id
          AND t.expires_at > now()
      )
    ORDER BY u.id LIMIT 500 FOR UPDATE OF u SKIP LOCKED
  )
  DELETE FROM auth.users WHERE id IN (SELECT id FROM doomed);

  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed;
END;
$$;

COMMENT ON FUNCTION public.cleanup_dormant_anonymous_users() IS
'Expire anonymous accounts dormant for 90 days, including those still holding clips. Complements cleanup_abandoned_anonymous_users(), which only removes empty ones. Cascades handle clipboard/devices/tokens; the clipboard delete trigger reclaims stored files. Bounded to 500 accounts per run.';

REVOKE ALL ON FUNCTION public.cleanup_dormant_anonymous_users() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cleanup_dormant_anonymous_users() TO service_role;

-- Daily is ample for a 90-day rule, and keeps this off the busy cron paths.
SELECT cron.unschedule(jobid) FROM cron.job
  WHERE jobname = 'expire-dormant-anonymous-accounts';
SELECT cron.schedule('expire-dormant-anonymous-accounts', '43 4 * * *',
  'SELECT public.cleanup_dormant_anonymous_users()');
