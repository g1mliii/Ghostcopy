import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'jsr:@supabase/supabase-js@2';
// Import Firebase Admin SDK via NPM compatibility
import admin from 'npm:firebase-admin@12.0.0';

// Initialize Firebase Admin outside the handler to reuse the connection across invocations
// This prevents "App already exists" errors and speeds up warm starts.
const serviceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT');
if (serviceAccountJson) {
  try {
    const serviceAccount = JSON.parse(serviceAccountJson);
    if (!admin.apps.length) {
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
      });
    }
  } catch (e) {
    console.error('[Notification] Error parsing FIREBASE_SERVICE_ACCOUNT:', e);
  }
} else {
  console.warn('[Notification] FIREBASE_SERVICE_ACCOUNT secret is missing.');
}

// CORS headers for client-side requests
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Server-side rate limiting (in-memory)
const rateLimitMap = new Map<string, { count: number; resetTime: number }>();
const RATE_LIMIT_MAX_CALLS = 60; // Max 60 calls per minute per user
const RATE_LIMIT_WINDOW_MS = 60 * 1000; // 1 minute

/**
 * Check and update rate limit for a user
 */
function checkRateLimit(userId: string): { allowed: boolean; remaining: number } {
  const now = Date.now();
  const userLimit = rateLimitMap.get(userId);

  if (!userLimit || now >= userLimit.resetTime) {
    rateLimitMap.set(userId, {
      count: 1,
      resetTime: now + RATE_LIMIT_WINDOW_MS,
    });
    return { allowed: true, remaining: RATE_LIMIT_MAX_CALLS - 1 };
  }

  if (userLimit.count >= RATE_LIMIT_MAX_CALLS) {
    return { allowed: false, remaining: 0 };
  }

  userLimit.count++;
  return { allowed: true, remaining: RATE_LIMIT_MAX_CALLS - userLimit.count };
}

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Create Supabase client
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_ANON_KEY') ?? '',
      {
        global: {
          headers: { Authorization: req.headers.get('Authorization')! },
        },
      }
    );

    // Get authenticated user
    const {
      data: { user },
      error: userError,
    } = await supabaseClient.auth.getUser();

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    // SERVER-SIDE RATE LIMITING
    const rateLimit = checkRateLimit(user.id);
    if (!rateLimit.allowed) {
      console.warn(`[Notification] Rate limit exceeded for user ${user.id}`);
      return new Response(
        JSON.stringify({
          error: 'Rate limit exceeded',
          message: 'Too many requests. Please wait before sending more notifications.',
          retry_after: 60,
        }),
        {
          status: 429,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'Retry-After': '60',
            'X-RateLimit-Limit': RATE_LIMIT_MAX_CALLS.toString(),
            'X-RateLimit-Remaining': rateLimit.remaining.toString(),
          },
        }
      );
    }

    // Parse request body
    const {
      content_preview,
      device_type,
      target_device_types,
      clipboard_id,
    } = await req.json();

    // Validate required fields
    if (!device_type || !clipboard_id) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields: device_type, clipboard_id' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    if (!['windows', 'macos', 'android', 'ios', 'linux'].includes(device_type)) {
      return new Response(
        JSON.stringify({ error: 'Invalid device_type' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    // ------------------------------------------------------------------
    // FETCH CLIPBOARD ITEM TO DETERMINE CONTENT TYPE & CONTENT
    // ------------------------------------------------------------------
    const { data: clipboardItem, error: clipboardError } = await supabaseClient
      .from('clipboard')
      .select('id, content_type, rich_text_format, file_size_bytes, content')
      .eq('id', clipboard_id)
      .eq('user_id', user.id)  // Security: ensure user owns this item
      .single();

    if (clipboardError || !clipboardItem) {
      console.error('[Notification] Failed to fetch clipboard item:', clipboardError);
      return new Response(
        JSON.stringify({ error: 'Clipboard item not found' }),
        {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    const contentType = clipboardItem.content_type || 'text';
    const isImage = contentType.startsWith('image_');
    const isRichText = contentType === 'html' || contentType === 'markdown';

    // For FCM data payload, include content if it's small enough (< 4KB max FCM payload)
    // Large content will be fetched by app using clipboard_id after notification tap
    let clipboardContent = '';
    if (!isImage && clipboardItem.content && clipboardItem.content.length < 4096) {
      clipboardContent = clipboardItem.content;
    }
    // If content is too large or is an image, app will fetch via clipboard_id

    // Determine notification title and body based on content type
    let notificationTitle: string;
    let notificationBody: string;

    if (isImage) {
      // For images, always use fallback notification (images are >4KB)
      const sizeKB = clipboardItem.file_size_bytes
        ? Math.round(clipboardItem.file_size_bytes / 1024)
        : 0;
      notificationTitle = `New image from ${device_type}`;
      notificationBody = sizeKB > 0
        ? `Image (${sizeKB}KB) - Tap to view`
        : 'Tap to view image';
      console.log(`[Notification] Image detected (${sizeKB}KB) - using fallback notification`);
    } else if (isRichText) {
      const format = clipboardItem.rich_text_format || 'rich text';
      notificationTitle = `New ${format} from ${device_type}`;
      notificationBody = content_preview
        ? content_preview.substring(0, 100)
        : 'Tap to view content';
    } else {
      // Plain text
      notificationTitle = `New clip from ${device_type}`;
      notificationBody = content_preview
        ? content_preview.substring(0, 100)
        : 'Tap to view content';
    }

    const targetText = target_device_types && target_device_types.length > 0
      ? target_device_types.join(', ')
      : 'all devices';
    console.log(`[Notification] User ${user.id} sending ${contentType} from ${device_type} to ${targetText}`);

    // Query devices table for FCM tokens
    let query = supabaseClient
      .from('devices')
      .select('id, device_type, device_name, fcm_token')
      .eq('user_id', user.id);

    // Filter by target device types if specified
    if (target_device_types && target_device_types.length > 0) {
      query = query.in('device_type', target_device_types);
    }

    const { data: devices, error: devicesError } = await query;

    if (devicesError) {
      console.error('[Notification] Error querying devices:', devicesError);
      return new Response(
        JSON.stringify({ error: 'Failed to query devices' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      );
    }

    if (!devices || devices.length === 0) {
      console.log('[Notification] No devices found with FCM tokens');
      return new Response(
        JSON.stringify({
          success: true,
          message: 'No devices registered for push notifications',
          devices_notified: 0,
        }),
        {
          status: 200,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'X-RateLimit-Limit': RATE_LIMIT_MAX_CALLS.toString(),
            'X-RateLimit-Remaining': rateLimit.remaining.toString(),
          },
        }
      );
    }

    console.log(`[Notification] Found ${devices.length} device(s) to notify`);

    // ------------------------------------------------------------------
    // SEND FCM NOTIFICATIONS (MODERN HTTP V1 API)
    // ------------------------------------------------------------------
    let successCount = 0;
    let failureCount = 0;

    if (admin.apps.length > 0) {
      // Filter out devices without tokens
      const validDevices = devices.filter(d => d.fcm_token);

      if (validDevices.length > 0) {
        // Construct message payloads
        const messages = validDevices.map(device => ({
          token: device.fcm_token,
          notification: {
            title: notificationTitle,
            body: notificationBody,
          },
          data: {
            // Data values MUST be strings in FCM
            clipboard_id: clipboard_id.toString(),
            device_type: device_type,
            content_type: contentType,
            // For images, app will fetch from storage using clipboard_id
            is_image: isImage ? 'true' : 'false',
            // Include content if small enough for native handlers
            clipboard_content: clipboardContent,
          },
          // Android configuration with click intent
          android: {
            priority: 'high' as const,
            notification: {
              // Click action triggers CopyActivity
              clickAction: 'com.ghostcopy.ghostcopy.COPY_ACTION',
            },
          },
          // APNs configuration for iOS with category for notification actions
          apns: {
            headers: {
              'apns-priority': '10',
            },
            payload: {
              aps: {
                // Category must match UNNotificationCategory in AppDelegate.swift
                category: 'CLIPBOARD_SYNC',
                'mutable-content': 1,
              },
            },
          },
        }));

        try {
          const batchResponse = await admin.messaging().sendEach(messages);
          successCount = batchResponse.successCount;
          failureCount = batchResponse.failureCount;

          if (failureCount > 0) {
            console.warn(`[Notification] ${failureCount} messages failed to send.`);
            // Iterate through responses to handle token errors
            batchResponse.responses.forEach((resp, idx) => {
              if (!resp.success && resp.error) {
                const errorCode = resp.error.code;
                if (errorCode === 'messaging/registration-token-not-registered' ||
                    errorCode === 'messaging/invalid-registration-token') {
                  console.log(`[Notification] Invalid/unregistered token for device ${validDevices[idx].id} - should be cleaned up`);
                }
              }
            });
          }
        } catch (fcmError) {
          console.error('[Notification] Critical FCM Error:', fcmError);
        }
      }
    } else {
      console.error('[Notification] Firebase Admin not initialized (Check secrets)');
    }

    // Update last_active timestamp for all queried devices
    const deviceIds = devices.map((d) => d.id);
    await supabaseClient
      .from('devices')
      .update({ last_active: new Date().toISOString() })
      .in('id', deviceIds);

    console.log(`[Notification] Process complete. Success: ${successCount}, Fail: ${failureCount}`);

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Notifications processed',
        content_type: contentType,
        is_image: isImage,
        devices_notified: successCount,
        devices_failed: failureCount,
        devices: devices.map((d) => ({
          device_type: d.device_type,
          device_name: d.device_name,
        })),
      }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json',
          'X-RateLimit-Limit': RATE_LIMIT_MAX_CALLS.toString(),
          'X-RateLimit-Remaining': rateLimit.remaining.toString(),
        },
      }
    );

  } catch (error: any) {
    console.error('[Notification] Unexpected error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    );
  }
});
