-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-05 05:31:37 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Minimal fix: Set immutable search_path for notify_mobile_devices_on_clipboard_insert
-- Only modifies the function configuration, preserves all existing logic

ALTER FUNCTION notify_mobile_devices_on_clipboard_insert()
SET search_path = 'public';

-- Verify the fix
COMMENT ON FUNCTION notify_mobile_devices_on_clipboard_insert() IS
'Smart trigger that only calls FCM edge function if mobile devices are targeted.
Desktop-only sends skip the edge function call entirely, saving invocation costs.
Search path is now immutably set to public (fixes security advisory).';
