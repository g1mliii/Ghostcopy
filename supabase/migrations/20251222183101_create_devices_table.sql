-- Recovered from production migration history on 2026-09-14.
--
-- This DDL was applied to production on 2025-12-22 18:31:01 through the Supabase
-- dashboard, which recorded it in supabase_migrations.schema_migrations
-- but never wrote a file to this directory. The SQL below is that
-- recorded statement text, verbatim.
--
-- It is ALREADY APPLIED. The file exists so the CLI migration history
-- matches production and `supabase db push` can manage future changes.
-- Do not edit it and do not re-run it by hand.

-- Create devices table to store FCM/APNs push tokens
-- Supports both authenticated and anonymous users
CREATE TABLE IF NOT EXISTS public.devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  device_type device_type_enum NOT NULL,
  device_name text CHECK (device_name IS NULL OR length(device_name) <= 255),
  fcm_token text NOT NULL CHECK (length(fcm_token) > 0 AND length(fcm_token) <= 4096),
  last_active timestamptz DEFAULT timezone('utc', now()) NOT NULL,
  created_at timestamptz DEFAULT timezone('utc', now()) NOT NULL,
  
  -- Prevent duplicate token registration for same user
  CONSTRAINT unique_user_token UNIQUE (user_id, fcm_token)
);

-- Performance indexes
CREATE INDEX idx_devices_user_id ON public.devices(user_id);
CREATE INDEX idx_devices_user_device_type ON public.devices(user_id, device_type);
CREATE INDEX idx_devices_last_active ON public.devices(last_active DESC);

-- Enable RLS
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Users (including anon) manage their own devices
-- Uses auth.uid() which works for both authenticated and anonymous users
CREATE POLICY "users_manage_own_devices"
  ON public.devices
  FOR ALL
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Comment for documentation
COMMENT ON TABLE public.devices IS 'Stores device registration tokens for push notifications. Supports both authenticated and anonymous users.';
COMMENT ON COLUMN public.devices.fcm_token IS 'FCM (Firebase Cloud Messaging) token for Android/iOS push notifications';
COMMENT ON COLUMN public.devices.device_type IS 'Device platform type';
COMMENT ON COLUMN public.devices.last_active IS 'Last time this device was active, used for cleanup of stale tokens';
