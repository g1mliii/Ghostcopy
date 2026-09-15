-- Silence rls_enabled_no_policy on the three service-only tables added in
-- 20260915000000_bound_cleanup_and_rate_limits.sql.
--
-- Those tables are already locked down correctly: RLS is on, and PUBLIC, anon
-- and authenticated hold no grants at all. Only service_role is granted, and
-- service_role has BYPASSRLS, so it never consults a policy. The absence of
-- policies IS the lockdown.
--
-- The linter cannot tell that apart from "someone enabled RLS and forgot to
-- write the policies", so it reports INFO on all three. An explicit deny-all
-- states the intent in the schema instead of leaving it to be inferred from an
-- empty pg_policies, and the finding goes away.
--
-- This changes no behaviour. Every function that touches these tables is
-- SECURITY DEFINER owned by postgres, so it bypasses RLS regardless; anon and
-- authenticated were already refused at the GRANT layer, one step before RLS
-- is even reached.

SET lock_timeout = '5s';

CREATE POLICY clipboard_cleanup_cursor_deny_all
  ON public.clipboard_cleanup_cursor
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

CREATE POLICY storage_rate_limits_deny_all
  ON public.storage_rate_limits
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

CREATE POLICY storage_cleanup_queue_deny_all
  ON public.storage_cleanup_queue
  FOR ALL TO anon, authenticated
  USING (false) WITH CHECK (false);

COMMENT ON TABLE public.clipboard_cleanup_cursor IS
  'Service-only. Cleanup progress cursor. No client role may read or write it.';
COMMENT ON TABLE public.storage_rate_limits IS
  'Service-only. Per-user storage action counters. No client role may read or write it.';
COMMENT ON TABLE public.storage_cleanup_queue IS
  'Service-only. Pending R2 object deletions. No client role may read or write it.';
