import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'jsr:@supabase/supabase-js@2';
// Import Firebase Admin SDK via NPM compatibility
import admin from 'npm:firebase-admin@12.0.0';
import { corsPreflight, json } from '../_shared/http.ts';
// Initialize Firebase Admin outside the handler to reuse the connection across invocations
// This prevents "App already exists" errors and speeds up warm starts.
const serviceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT');
if (serviceAccountJson) {
  try {
    const serviceAccount = JSON.parse(serviceAccountJson);
    if (!admin.apps.length) {
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount)
      });
    }
  } catch (e) {
    console.error('[Notification] Error parsing FIREBASE_SERVICE_ACCOUNT:', e);
  }
} else {
  console.warn('[Notification] FIREBASE_SERVICE_ACCOUNT secret is missing.');
}
// CORS headers for client-side requests
// Service role client for operations that bypass RLS:
// rate limit reads and stale FCM token cleanup.
const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
// DB-based rate limit — reads the existing user_rate_limit table so the limit
// is consistent across all Edge Function instances (no per-instance Map state).
// Notifications are 1:1 with clipboard inserts, so the same 10/min window applies.
const RATE_LIMIT_MAX_CALLS = 10;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
function normalizeTargetDeviceTypes(value) {
  if (Array.isArray(value)) {
    return value;
  }
  if (typeof value === 'string' && value.length > 0) {
    return [
      value
    ];
  }
  return null;
}
async function checkRateLimit(userId) {
  const { data, error } = await supabaseAdmin.from('user_rate_limit').select('insert_count, window_start').eq('user_id', userId).maybeSingle();
  if (error) {
    // Fail open on DB error to avoid blocking legitimate requests
    console.warn('[Notification] Rate limit check failed, failing open:', error.message);
    return {
      allowed: true,
      remaining: RATE_LIMIT_MAX_CALLS
    };
  }
  if (!data) {
    return {
      allowed: true,
      remaining: RATE_LIMIT_MAX_CALLS
    };
  }
  const windowExpired = Date.now() - new Date(data.window_start).getTime() > RATE_LIMIT_WINDOW_MS;
  if (windowExpired) {
    return {
      allowed: true,
      remaining: RATE_LIMIT_MAX_CALLS - 1
    };
  }
  const remaining = RATE_LIMIT_MAX_CALLS - data.insert_count;
  return {
    // Strictly less-than: `<=` admitted the (MAX + 1)th call, and returned it
    // alongside `remaining: 0` - the header contradicting the decision.
    allowed: data.insert_count < RATE_LIMIT_MAX_CALLS,
    remaining: Math.max(0, remaining)
  };
}
Deno.serve(async (req)=>{
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return corsPreflight();
  }
  try {
    // Create Supabase client
    const supabaseClient = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
      global: {
        headers: {
          Authorization: req.headers.get('Authorization')
        }
      }
    });
    // The database trigger notify_mobile_devices_on_clipboard_insert calls this
    // function with the SERVICE ROLE key. That JWT carries role=service_role and
    // no `sub` claim, so auth.getUser() rejects it - which meant every
    // trigger-driven notification returned 401 before even reading the body,
    // and mobile push silently never fired. Detect that caller explicitly and
    // take the identity from the row it is reporting instead.
    const authHeader = req.headers.get('Authorization');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const isServiceRole = !!serviceRoleKey && authHeader === `Bearer ${serviceRoleKey}`;

    // Body is parsed up front because the service-role path needs record.user_id
    // to establish identity.
    const body = await req.json();

    let userId = null;
    if (isServiceRole) {
      userId = typeof body?.record?.user_id === 'string' ? body.record.user_id : null;
      if (!userId) {
        return json({ error: 'record.user_id is required for service-role calls' }, 400);
      }
    } else {
      const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
      if (userError || !user) {
        return json({ error: 'Unauthorized' }, 401);
      }
      // A normal caller may only ever act on its own rows. Without this an
      // authenticated user could POST an arbitrary `record` naming someone
      // else's user_id and push notifications at their devices.
      // Note the check is on `record.user_id !== user.id`, NOT on a truthy
      // user_id. Requiring truthiness let a caller simply omit the field: the
      // guard passed, clipboardItemFromWebhook was then built from the
      // attacker's own payload, and that non-null item skipped the DB fetch
      // below - the fetch that enforces both `.eq('user_id', ...)` and the
      // 5-minute recency replay guard. Omitting user_id now fails here.
      if (body?.record && body.record.user_id !== user.id) {
        console.warn('[Notification] record.user_id does not match caller - refusing');
        return json({ error: 'Forbidden' }, 403);
      }
      userId = user.id;
    }
    // SERVER-SIDE RATE LIMITING
    const rateLimit = await checkRateLimit(userId);
    if (!rateLimit.allowed) {
      console.warn(`[Notification] Rate limit exceeded for user ${userId}`);
      return json({
        error: 'Rate limit exceeded',
        message: 'Too many requests. Please wait before sending more notifications.',
        retry_after: 60
      }, 429);
    }
    // (body parsed above, before auth, for the service-role path)
    // Handle webhook payload vs client invocation
    let clipboard_id = null;
    let device_type = null;
    let target_device_types;
    let content_preview = null;
    let clipboardItemFromWebhook = null;
    if (body.record) {
      // Webhook payload format from database
      const record = body.record;
      clipboard_id = record.id;
      device_type = record.device_type;
      target_device_types = normalizeTargetDeviceTypes(record.target_device_type);
      clipboardItemFromWebhook = {
        id: record.id,
        content: record.content ?? null,
        content_type: record.content_type ?? null,
        file_size_bytes: record.file_size_bytes ?? null,
        rich_text_format: record.rich_text_format ?? null
      };
      // Generate content_preview from content if not in webhook
      if (typeof record.content === 'string' && !content_preview) {
        content_preview = record.content.substring(0, 100);
      }
    } else {
      // Client invocation format (deprecated after webhook migration)
      clipboard_id = typeof body.clipboard_id === 'number' ? body.clipboard_id : null;
      device_type = typeof body.device_type === 'string' ? body.device_type : null;
      target_device_types = normalizeTargetDeviceTypes(body.target_device_types);
      content_preview = typeof body.content_preview === 'string' ? body.content_preview : null;
    }
    // Validate required fields
    if (!device_type || clipboard_id == null) {
      return json({ error: 'Missing required fields: device_type, clipboard_id' }, 400);
    }
    if (![
      'windows',
      'macos',
      'android',
      'ios',
      'linux'
    ].includes(device_type)) {
      return json({ error: 'Invalid device_type' }, 400);
    }
    // Note: Desktop-only filtering is now handled by database trigger.
    // This edge function is only called if mobile devices are targeted.
    // See: supabase/migrations/20260104000002_replace_webhook_with_smart_trigger.sql
    // ------------------------------------------------------------------
    // FETCH CLIPBOARD ITEM TO DETERMINE CONTENT TYPE & CONTENT
    // ------------------------------------------------------------------
    let clipboardItem = clipboardItemFromWebhook;
    // Only fetch from DB if not from webhook
    if (!clipboardItem) {
      // Recency check: only allow notifications for items created in the last 5 minutes.
      // Prevents replay-based notification spam using old clipboard_ids.
      const fiveMinutesAgo = new Date(Date.now() - 5 * 60 * 1000).toISOString();
      const { data: dbItem, error: clipboardError } = await supabaseClient.from('clipboard').select('id, content_type, rich_text_format, file_size_bytes, content').eq('id', clipboard_id).eq('user_id', userId) // Security: ensure user owns this item
      .gte('created_at', fiveMinutesAgo).single();
      if (clipboardError || !dbItem) {
        console.error('[Notification] Failed to fetch clipboard item:', clipboardError);
        return json({ error: 'Clipboard item not found' }, 404);
      }
      clipboardItem = dbItem;
    }
    const contentType = clipboardItem.content_type || 'text';
    const isImage = contentType.startsWith('image_');
    // Push infrastructure and OS notification history must never receive a
    // clipboard value, preview, filename, or size. The authenticated app syncs
    // the item after the user opens GhostCopy.
    // Say what the tap will actually do. Only text-shaped clips are staged by the
    // background isolate for an instant clipboard write; images and files need a
    // download and a share sheet, so tapping those opens the app. Promising "Tap
    // to copy" for an image would be a straight lie about the next screen.
    const isFile = contentType.startsWith('file_');
    const notificationTitle = isImage
      ? 'Image received'
      : isFile
        ? 'File received'
        : 'New clipboard item';
    const notificationBody = isImage || isFile
      ? 'Tap to open in GhostCopy'
      : 'Tap to copy';
    const targetText = target_device_types && target_device_types.length > 0 ? target_device_types.join(', ') : 'all devices';
    console.log(`[Notification] User ${userId} sending ${contentType} from ${device_type} to ${targetText}`);
    // Query devices table for FCM tokens
    let query = supabaseClient.from('devices').select('id, device_type, device_name, fcm_token').eq('user_id', userId).neq('device_type', device_type); // Skip self-notifications: don't send to sending device type
    // Filter by target device types if specified
    if (target_device_types && target_device_types.length > 0) {
      query = query.in('device_type', target_device_types);
    }
    const { data: rawDevices, error: devicesError } = await query;
    if (devicesError) {
      console.error('[Notification] Error querying devices:', devicesError);
      return json({ error: 'Failed to query devices' }, 500);
    }
    const devices = rawDevices ?? [];
    if (devices.length === 0) {
      console.log('[Notification] No devices found with FCM tokens');
      return json({
        success: true,
        message: 'No devices registered for push notifications',
        devices_notified: 0
      });
    }
    console.log(`[Notification] Found ${devices.length} device(s) to notify`);
    // Started here rather than after the send: it does not depend on the FCM
    // result, and awaiting it afterwards added a full Postgres round-trip to
    // the push path before this function could respond.
    const deviceIds = devices.map((d)=>d.id);
    const lastActiveUpdate = deviceIds.length > 0 ? supabaseClient.from('devices').update({
      last_active: new Date().toISOString()
    }).in('id', deviceIds) : null;
    // ------------------------------------------------------------------
    // SEND FCM NOTIFICATIONS (MODERN HTTP V1 API)
    // ------------------------------------------------------------------
    let successCount = 0;
    let failureCount = 0;
    if (admin.apps.length > 0) {
      // Filter out devices without tokens
      const validDevices = devices.filter((device)=>typeof device.fcm_token === 'string' && device.fcm_token.length > 0);
      if (validDevices.length > 0) {
        // Construct message payloads
        const messages = validDevices.map((device)=>({
            token: device.fcm_token,
            notification: {
              title: notificationTitle,
              body: notificationBody
            },
            data: {
              // Data values MUST be strings in FCM
              clipboard_id: clipboard_id.toString(),
              device_type: device_type,
              content_type: contentType
            },
            // Tapping routes straight to CopyActivity - a translucent, no-history
            // activity that writes the clipboard and finishes - instead of cold
            // starting the full Flutter app (~2.5s, and visibly "opens GhostCopy").
            //
            // Safe despite CopyActivity being exported="false": the click_action
            // PendingIntent is constructed by the FCM SDK inside this app's own
            // process, and Android permits same-UID callers to start non-exported
            // components. No other app can reach COPY_ACTION.
            //
            // The push still carries no clipboard value - CopyActivity reads the
            // plaintext the background isolate cached on arrival, and falls back to
            // opening the app when that cache misses.
            android: {
              priority: 'high',
              notification: {
                clickAction: 'com.ghostcopy.ghostcopy.COPY_ACTION',
                channelId: 'ghostcopy_notifications'
              }
            },
            // APNs configuration for iOS with category for notification actions
            apns: {
              headers: {
                'apns-priority': '10'
              },
              payload: {
                aps: {
                  // Category must match UNNotificationCategory in AppDelegate.swift
                  category: 'CLIPBOARD_SYNC',
                  'mutable-content': 1
                }
              }
            }
          }));
        try {
          const batchResponse = await admin.messaging().sendEach(messages);
          successCount = batchResponse.successCount;
          failureCount = batchResponse.failureCount;
          if (failureCount > 0) {
            console.warn(`[Notification] ${failureCount} messages failed to send.`);
            // Collect device IDs whose tokens FCM rejected as invalid/unregistered
            const staleDeviceIds = [];
            batchResponse.responses.forEach((resp, idx)=>{
              if (!resp.success && resp.error) {
                const errorCode = resp.error.code;
                if (errorCode === 'messaging/registration-token-not-registered' || errorCode === 'messaging/invalid-registration-token') {
                  staleDeviceIds.push(validDevices[idx].id);
                }
              }
            });
            if (staleDeviceIds.length > 0) {
              const { error: updateError } = await supabaseAdmin.from('devices').update({
                fcm_token: null
              }).in('id', staleDeviceIds);
              if (updateError) {
                console.error('[Notification] Failed to clear stale FCM tokens:', updateError);
              } else {
                console.log(`[Notification] Cleared ${staleDeviceIds.length} stale FCM token(s)`);
              }
            }
          }
        } catch (fcmError) {
          console.error('[Notification] Critical FCM Error:', fcmError);
        }
      }
    } else {
      console.error('[Notification] Firebase Admin not initialized (Check secrets)');
    }
    const warnings = [];
    if (lastActiveUpdate != null) {
      const { error: lastActiveError } = await lastActiveUpdate;
      if (lastActiveError) {
        const warning = `Failed to update last_active for ${deviceIds.length} device(s): ${lastActiveError.message}`;
        warnings.push(warning);
        console.error(`[Notification] ${warning}`);
      }
    }
    console.log(`[Notification] Process complete. Success: ${successCount}, Fail: ${failureCount}`);
    return json({
      success: true,
      message: 'Notifications processed',
      content_type: contentType,
      is_image: isImage,
      devices_notified: successCount,
      devices_failed: failureCount,
      warnings,
      devices: devices.map((d)=>({
          device_type: d.device_type,
          device_name: d.device_name
        }))
    });
  } catch (error) {
    console.error('[Notification] Unexpected error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
