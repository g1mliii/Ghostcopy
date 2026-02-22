import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { S3Client, DeleteObjectCommand, PutObjectCommand } from 'npm:@aws-sdk/client-s3@3.600.0';
import { getSignedUrl } from 'npm:@aws-sdk/s3-request-presigner@3.600.0';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID') ?? '';
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID') ?? '';
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY') ?? '';
// .trim() guards against accidental whitespace when secrets are set via dashboard copy-paste
const R2_BUCKET_NAME = (Deno.env.get('R2_BUCKET_NAME') ?? 'ghostcopy-files').trim();
const R2_PUBLIC_URL = (Deno.env.get('R2_PUBLIC_URL') ?? '').trim();

const s3Client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
  },
  forcePathStyle: false,
});

async function authenticate(req: Request): Promise<{ userId: string | null; error: Response | null }> {
  const authHeader = req.headers.get('Authorization') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  if (authHeader === `Bearer ${serviceRoleKey}`) {
    return { userId: 'service-role', error: null };
  }

  const supabaseClient = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user }, error: userError } = await supabaseClient.auth.getUser();
  if (userError || !user) {
    return {
      userId: null,
      error: new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }),
    };
  }

  return { userId: user.id, error: null };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { action, path } = body;

    if (!action || !path) {
      return new Response(JSON.stringify({ error: 'Missing action or path' }), {
        status: 400,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const { userId, error: authError } = await authenticate(req);
    if (authError) return authError;

    if (userId !== 'service-role' && !path.startsWith(userId!)) {
      return new Response(JSON.stringify({ error: 'Forbidden' }), {
        status: 403,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    if (action === 'upload') {
      // Generate presigned PUT URL — client uploads directly to R2 (zero Supabase bandwidth)
      // ContentType is intentionally omitted from the command so the signed headers
      // only include 'host', allowing the client to PUT without matching a content-type.
      const command = new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: path,
      });
      const presignedUrl = await getSignedUrl(s3Client, command, { expiresIn: 3600 });
      const publicUrl = `${R2_PUBLIC_URL}/${path}`;

      console.log(`[storage-presign] Presigned upload URL generated for: ${path}`);

      return new Response(
        JSON.stringify({ presignedUrl, publicUrl }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    if (action === 'delete') {
      await s3Client.send(new DeleteObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: path,
      }));
      console.log(`[storage-presign] Deleted: ${path}`);
      return new Response(
        JSON.stringify({ success: true }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    return new Response(JSON.stringify({ error: 'Invalid action' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });

  } catch (error: any) {
    console.error('[storage-presign] Error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
