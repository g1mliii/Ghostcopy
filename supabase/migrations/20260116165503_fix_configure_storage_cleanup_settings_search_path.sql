-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2026-01-16 16:55:03 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Fix RLS security issue: Set explicit search_path on configure_storage_cleanup_settings
-- Date: 2026-01-15
-- Issue: Function has role mutable search_path (security vulnerability)
-- Fix: Add SET search_path to prevent search path injection attacks

-- Drop the old function (if it exists from old migration)
DROP FUNCTION IF EXISTS configure_storage_cleanup_settings(text, text);

-- Note: This function is no longer needed since we're using existing vault secrets
-- (fcm_service_role_key and supabase_api_url)
-- But if it was created, we'll leave it as a helper function with proper security

-- Recreate with proper search_path security
CREATE OR REPLACE FUNCTION configure_storage_cleanup_settings(
  p_supabase_url text,
  p_service_role_key text
)
RETURNS void AS $$
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
$$ LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public';  -- ✅ FIX: Explicit search_path prevents injection attacks

COMMENT ON FUNCTION configure_storage_cleanup_settings(text, text) IS
'DEPRECATED: Helper function to configure storage cleanup settings.
No longer needed - storage cleanup uses existing vault secrets (fcm_service_role_key, supabase_api_url).
Kept for backwards compatibility with explicit search_path for security.';
