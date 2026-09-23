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
const s3Client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY
  },
  forcePathStyle: false
});
async function authenticate(req: Request): Promise<
  { userId: string; error: null } | { userId: null; error: Response }
> {
  const authHeader = req.headers.get('Authorization') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (serviceRoleKey && authHeader === `Bearer ${serviceRoleKey}`) {
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
function serviceClient() {
  return createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', {
    auth: { persistSession: false, autoRefreshToken: false }
  });
}
async function checkStorageRateLimit(userId: string, action: string) {
  const { data, error } = await serviceClient().rpc('check_storage_rate_limit', {
    p_user_id: userId, p_action: action
  });
  if (error || !data?.[0]) throw new Error('Storage rate limit unavailable');
  return { allowed: data[0].allowed, retryAfterSeconds: data[0].retry_after_seconds };
}

interface CleanupRow {
  id: number;
  owner_id: string;
  storage_path: string;
}
/** Per-request cap, so one slow answer from R2 cannot eat the caller's time. */
const R2_REQUEST_TIMEOUT_MS = 8000;
/**
 * No new delete starts after this. pg_net gives the whole call 30 seconds;
 * rows left unfinished keep their lease and are retried on the next run.
 */
const BATCH_BUDGET_MS = 20000;
const DELETE_CONCURRENCY = 8;

/**
 * Delete one object: a presigned DELETE, sent with fetch.
 *
 * Not s3Client.send. In the Edge runtime that call never came back: every
 * delete_queued run from the storage cleanup cron timed out at pg_net's 30
 * seconds, so queued files were leased and retried every five minutes for
 * days (1,091 attempts on the oldest by 2026-09-23) and nothing was ever
 * removed from R2 - and the single-object 'delete' action made the same call.
 * Signing does work here, uploads and downloads have always used it, and
 * fetch is the runtime's own.
 *
 * Only a 2xx counts. DeleteObject is idempotent - R2, like S3, answers 204
 * for a key that is already gone - so a 404 means something else is missing:
 * the bucket, or the endpoint. Acknowledging those would drop the queue rows
 * for good while the files stayed put, with no way to retry once the
 * configuration was fixed.
 */
async function deleteObject(key: string): Promise<boolean> {
  const url = await getSignedUrl(s3Client, new DeleteObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key
  }), { expiresIn: 60 });
  const response = await fetch(url, {
    method: 'DELETE',
    signal: AbortSignal.timeout(R2_REQUEST_TIMEOUT_MS)
  });
  await response.body?.cancel();
  return response.ok;
}

async function deleteQueuedObjects() {
  const client = serviceClient();
  // The database leases at most 500 rows. A failed invocation leaves them
  // retryable after five minutes, including crashes after R2 accepted a delete.
  const { data, error } = await client.rpc('claim_storage_cleanup_batch');
  const rows = data as CleanupRow[] | null;
  if (error) throw error;
  if (!rows?.length) return json({ success: true, deleted: 0 });
  const valid = rows.filter((row) => typeof row.storage_path === 'string' &&
    row.storage_path.startsWith(`${row.owner_id}/`));
  if (valid.length !== rows.length) throw new Error('Invalid cleanup owner prefix');
  // Acknowledge only deletes R2 confirmed; every other row keeps its lease.
  const started = Date.now();
  const ids: number[] = [];
  let next = 0;
  const worker = async () => {
    while (next < valid.length && Date.now() - started < BATCH_BUDGET_MS) {
      const row = valid[next++];
      try {
        if (await deleteObject(row.storage_path)) ids.push(row.id);
      } catch (e) {
        console.error('[storage-presign] R2 delete failed:', row.storage_path, e);
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(DELETE_CONCURRENCY, valid.length) }, worker));
  if (ids.length) {
    const { error: ackError } = await client.rpc('acknowledge_storage_cleanup', { p_ids: ids });
    if (ackError) throw ackError;
  }
  return json({ success: ids.length === rows.length, deleted: ids.length }, ids.length === rows.length ? 200 : 502);
}
Deno.serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return corsPreflight();
  }
  try {
    const body = await req.json();
    const { action, path } = body;
    if (action === 'delete_queued') {
      const { userId, error: authError } = await authenticate(req);
      if (authError) return authError;
      if (userId !== 'service-role') return json({ error: 'Forbidden' }, 403);
      return await deleteQueuedObjects();
    }
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
      const rateLimit = await checkStorageRateLimit(userId, action);
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
      if (!await deleteObject(path)) {
        return json({ error: 'Delete failed' }, 502);
      }
      console.log(`[storage-presign] Deleted: ${path}`);
      return json({ success: true });
    }
    return json({ error: 'Invalid action' }, 400);
  } catch (error) {
    console.error('[storage-presign] Error:', error);
    return json({ error: 'Internal server error' }, 500);
  }
});
