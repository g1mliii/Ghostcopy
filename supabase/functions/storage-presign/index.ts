import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { DeleteObjectCommand, GetObjectCommand, PutObjectCommand, S3Client } from 'npm:@aws-sdk/client-s3@3.600.0';
import { getSignedUrl } from 'npm:@aws-sdk/s3-request-presigner@3.600.0';
import { corsPreflight, json } from '../_shared/http.ts';
const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID') ?? '';
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID') ?? '';
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY') ?? '';
// .trim() guards against accidental whitespace when secrets are set via dashboard copy-paste
const R2_BUCKET_NAME = (Deno.env.get('R2_BUCKET_NAME') ?? 'ghostcopy-files').trim();
const DOWNLOAD_URL_TTL_SECONDS = 300;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const STORAGE_RATE_LIMITS = {
  upload: 20,
  download: 120,
  delete: 30
};
const storageRateLimitCache = new Map();
const s3Client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY
  },
  forcePathStyle: false
});
async function authenticate(req) {
  const authHeader = req.headers.get('Authorization') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (authHeader === `Bearer ${serviceRoleKey}`) {
    return {
      userId: 'service-role',
      error: null
    };
  }
  const supabaseClient = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: {
      headers: {
        Authorization: authHeader
      }
    }
  });
  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
  if (userError || !user) {
    return {
      userId: null,
      error: json({ error: 'Unauthorized' }, 401)
    };
  }
  return {
    userId: user.id,
    error: null
  };
}
function checkStorageRateLimit(userId, action) {
  const nowMs = Date.now();
  const cacheKey = `${userId}:${action}`;
  const maxCalls = STORAGE_RATE_LIMITS[action];
  for (const [key, entry] of storageRateLimitCache.entries()){
    if (nowMs - entry.windowStartMs > RATE_LIMIT_WINDOW_MS) {
      storageRateLimitCache.delete(key);
    }
  }
  const current = storageRateLimitCache.get(cacheKey);
  if (current == null || nowMs - current.windowStartMs > RATE_LIMIT_WINDOW_MS) {
    storageRateLimitCache.set(cacheKey, {
      count: 1,
      windowStartMs: nowMs
    });
    return {
      allowed: true,
      retryAfterSeconds: 0
    };
  }
  if (current.count >= maxCalls) {
    const retryAfterSeconds = Math.max(1, Math.ceil((RATE_LIMIT_WINDOW_MS - (nowMs - current.windowStartMs)) / 1000));
    return {
      allowed: false,
      retryAfterSeconds
    };
  }
  storageRateLimitCache.set(cacheKey, {
    count: current.count + 1,
    windowStartMs: current.windowStartMs
  });
  return {
    allowed: true,
    retryAfterSeconds: 0
  };
}
Deno.serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return corsPreflight();
  }
  try {
    const body = await req.json();
    const { action, path } = body;
    if (typeof action !== 'string' || typeof path !== 'string' || action.length === 0 || path.length === 0) {
      return json({ error: 'Missing action or path' }, 400);
    }
    if (action !== 'upload' && action !== 'download' && action !== 'delete') {
      return json({ error: 'Invalid action' }, 400);
    }
    if (path.startsWith('/') || path.includes('..') || path.includes('\\') || path.includes('\u0000') || path.split('/').some((segment)=>segment.length === 0)) {
      return json({ error: 'Invalid storage path' }, 400);
    }
    const { userId, error: authError } = await authenticate(req);
    if (authError) return authError;
    // A privileged trigger calls this function with the service key. It must
    // still prove the R2 object belongs to the row owner; otherwise the
    // service role becomes a confused deputy for arbitrary-object deletion.
    const ownerId = userId === 'service-role' ? typeof body.ownerId === 'string' ? body.ownerId : null : userId;
    if (ownerId == null || !path.startsWith(`${ownerId}/`)) {
      return json({ error: 'Forbidden' }, 403);
    }
    const isUserAction = userId !== 'service-role';
    // `action` was already narrowed to exactly the three rate-limited actions
    // above, so there is nothing further to test here.
    if (isUserAction) {
      const rateLimit = checkStorageRateLimit(userId, action);
      if (!rateLimit.allowed) {
        return json({
          error: 'Rate limit exceeded',
          retryAfter: rateLimit.retryAfterSeconds
        }, 429);
      }
    }
    if (action === 'upload') {
      // Server-side file size enforcement (matches client 10MB limit)
      const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB
      // `size` is REQUIRED. It was optional, and omitting it skipped the limit
      // check AND left ContentLength off the signed command - so the returned
      // URL accepted an object of any size for a full hour. Anonymous sign-in
      // is enabled, so anyone could mint a JWT and upload unbounded data to R2.
      const size = typeof body.size === 'number' && Number.isFinite(body.size) ? body.size : null;
      if (size === null) {
        return json({ error: 'size is required for upload' }, 400);
      }
      if (!Number.isInteger(size) || size <= 0 || size > MAX_FILE_SIZE) {
        return json({ error: 'File size must be between 1 byte and 10MB' }, 413);
      }
      // Generate presigned PUT URL — client uploads directly to R2 (zero Supabase bandwidth)
      // ContentType is intentionally omitted from the command so the signed headers
      // only include 'host', allowing the client to PUT without matching a content-type.
      // When size is provided, ContentLength locks the presigned URL to that exact size.
      // ContentLength is always signed now, pinning the URL to that exact size.
      const command = new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: path,
        ContentLength: size
      });
      const presignedUrl = await getSignedUrl(s3Client, command, {
        expiresIn: 3600
      });
      console.log(`[storage-presign] Presigned upload URL generated for: ${path}`);
      return json({ presignedUrl, storagePath: path });
    }
    if (action === 'download') {
      const command = new GetObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: path
      });
      const downloadUrl = await getSignedUrl(s3Client, command, {
        expiresIn: DOWNLOAD_URL_TTL_SECONDS
      });
      console.log(`[storage-presign] Signed download URL generated for: ${path}`);
      return json({ downloadUrl, expiresIn: DOWNLOAD_URL_TTL_SECONDS });
    }
    if (action === 'delete') {
      await s3Client.send(new DeleteObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: path
      }));
      console.log(`[storage-presign] Deleted: ${path}`);
      return json({ success: true });
    }
  } catch (error) {
    console.error('[storage-presign] Error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
