-- DEPRECATED: Use database trigger instead (migration 20260104000002)
-- Date: 2026-01-04
-- Description: Originally used webhooks, now replaced with smart database trigger
-- Reason: Database trigger can check target_device_type and skip unnecessary edge function calls

-- NOTE: If you previously set up a webhook in Supabase Dashboard, you can now delete it.
-- The database trigger in migration 20260104000002 replaces it with smarter filtering.

-- This file is kept for migration history only.
-- All functionality is now handled by: notify_mobile_devices_on_clipboard_insert() trigger
