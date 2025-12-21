# Clipboard Cleanup - Production Setup Guide

## Overview
This document explains how to set up the scheduled cleanup for old clipboard items. The system uses:
- **Supabase Edge Function** (`cleanup-old-clips`) - runs the cleanup logic
- **GitHub Actions** - triggers the function on a schedule
- **Bearer Token Authentication** - secures the function

## Setup Steps

### 1. Get Your Service Role Key

1. Go to Supabase Dashboard: https://app.supabase.com
2. Select your project: **GhostCopy**
3. Go to **Settings** → **API**
4. Copy the **service_role key** (the long JWT token starting with `eyJ...`)
5. ⚠️ **KEEP THIS SECRET** - never commit it to git

### 2. Generate a Function Secret

Generate a random, strong secret string:

```bash
openssl rand -base64 32
```

This will output something like:
```
KL9xmPqRsTuVwXyZ2AbCdEfGhIjKlMnOpQrStUvWxYz=
```

Save this value - you'll use it in the next steps.

### 3. Configure Supabase Edge Function Secrets

1. Go to: https://app.supabase.com/project/xhbggxftvnlkotvehwmj/functions
2. Click the **cleanup-old-clips** function
3. Click **"Secrets"** tab
4. Add these three secrets:

| Name | Value |
|------|-------|
| `SUPABASE_URL` | `https://xhbggxftvnlkotvehwmj.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | (paste your service role key from step 1) |
| `FUNCTION_SECRET` | (paste the secret from step 2) |

5. Save

### 4. Configure GitHub Secret

1. Go to: https://github.com/g1mliii/Ghostcopy/settings/secrets/actions
2. Click **"New repository secret"**
3. Add:
   - **Name:** `SUPABASE_CLEANUP_SECRET`
   - **Value:** (same value as `FUNCTION_SECRET` from step 2)
4. Click **"Add secret"**

## Testing

### Test the Workflow Manually

1. Go to: https://github.com/g1mliii/Ghostcopy/actions
2. Click **"Cleanup old clipboard items"** workflow
3. Click **"Run workflow"** → **"Run workflow"**
4. Wait for it to complete
5. Check the logs - you should see:
   ```
   Response Body: {"success":true,"message":"Successfully deleted..."}
   HTTP Status: 200
   ```

### Test the Function Directly

```bash
curl -X POST \
  https://xhbggxftvnlkotvehwmj.supabase.co/functions/v1/cleanup-old-clips \
  -H "Authorization: Bearer YOUR_FUNCTION_SECRET" \
  -H "Content-Type: application/json"
```

Expected response:
```json
{
  "success": true,
  "message": "Successfully deleted clipboard items older than 30 days",
  "timestamp": "2025-12-21T12:34:56.789Z"
}
```

## Schedule

The cleanup runs automatically at **2 AM UTC daily**.

To change the schedule, edit `.github/workflows/cleanup-old-clips.yml` line 11:

```yaml
- cron: '0 2 * * *'   # Change this
```

Common schedules:
- `'0 2 * * *'` = 2 AM UTC daily
- `'0 */6 * * *'` = Every 6 hours
- `'0 0 * * 0'` = Every Sunday midnight
- `'0 3 * * *'` = 3 AM UTC daily

## How It Works

### Synchronous Cleanup (on every insert)
When a user inserts a clipboard item, a database trigger runs:
```sql
DELETE FROM clipboard
WHERE user_id = NEW.user_id
AND created_at < now() - 2 hours
AND id NOT IN (SELECT id LIMIT 20)
```
This keeps only 20 recent items per user, preventing unbounded growth.

### Deep Cleanup (scheduled, off-peak)
This Edge Function runs at 2 AM UTC daily:
```sql
DELETE FROM clipboard WHERE created_at < now() - 30 days
VACUUM ANALYZE
```
This deletes all items older than 30 days and reclaims disk space.

## Security

- ✅ Service Role Key = Only used in Supabase Edge Function (runs server-side)
- ✅ Function Secret = Used to authenticate GitHub's requests
- ✅ No secrets exposed in GitHub Actions logs
- ✅ RLS policies still enforce user isolation
- ✅ Function validates Bearer token before executing cleanup

## Troubleshooting

**Workflow shows "ERROR: SUPABASE_CLEANUP_SECRET not set"**
- You haven't added the GitHub secret yet
- Go to Settings → Secrets and Actions and add `SUPABASE_CLEANUP_SECRET`

**Workflow shows "HTTP 401"**
- The Bearer token doesn't match `FUNCTION_SECRET` in Supabase
- Regenerate both and ensure they're identical

**Cleanup doesn't seem to work**
- Check the Supabase function logs: https://app.supabase.com/project/xhbggxftvnlkotvehwmj/functions/cleanup-old-clips
- Run the test curl command above to verify the function works

## What Gets Deleted

- ✅ Clipboard items older than **30 days**
- ✅ Orphaned clipboard_content rows (via cascade delete)
- ✅ Only metadata and encrypted content (never unencrypted data)

## What Doesn't Get Deleted

- ❌ Recent items (< 30 days old)
- ❌ Items from the last 20 per user (synchronous cleanup)
- ❌ Active user data during any inserts
