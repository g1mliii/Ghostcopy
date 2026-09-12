import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { S3Client, PutObjectCommand } from 'npm:@aws-sdk/client-s3@3.600.0';
const R2_ACCOUNT_ID = Deno.env.get('R2_ACCOUNT_ID') ?? '';
const R2_ACCESS_KEY_ID = Deno.env.get('R2_ACCESS_KEY_ID') ?? '';
const R2_SECRET_ACCESS_KEY = Deno.env.get('R2_SECRET_ACCESS_KEY') ?? '';
const R2_BUCKET_NAME = Deno.env.get('R2_BUCKET_NAME') ?? 'ghostcopy-files';
const R2_PUBLIC_URL = Deno.env.get('R2_PUBLIC_URL') ?? '';
const s3Client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY
  }
});
Deno.serve(async (req)=>{
  // Only allow service role key
  const authHeader = req.headers.get('Authorization') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({
      error: 'Unauthorized'
    }), {
      status: 401
    });
  }
  const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', serviceRoleKey);
  // Get all items with storage paths
  const { data: items, error } = await supabase.from('clipboard').select('id, content, storage_path, mime_type').not('storage_path', 'is', null);
  if (error) {
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500
    });
  }
  const results = [];
  for (const item of items){
    try {
      console.log(`[migrate-to-r2] Processing item ${item.id}: ${item.storage_path}`);
      // Skip if already migrated to R2
      if (item.content.includes('r2.dev')) {
        results.push({
          id: item.id,
          status: 'skipped',
          reason: 'already on R2'
        });
        continue;
      }
      // Download from Supabase Storage using admin client
      const { data: fileData, error: downloadError } = await supabase.storage.from('clipboard-files').download(item.storage_path);
      if (downloadError || !fileData) {
        results.push({
          id: item.id,
          status: 'failed',
          reason: `download failed: ${downloadError?.message}`
        });
        continue;
      }
      const bytes = new Uint8Array(await fileData.arrayBuffer());
      console.log(`[migrate-to-r2] Downloaded ${bytes.length} bytes`);
      // Upload to R2
      const command = new PutObjectCommand({
        Bucket: R2_BUCKET_NAME,
        Key: item.storage_path,
        Body: bytes,
        ContentType: item.mime_type ?? 'application/octet-stream'
      });
      await s3Client.send(command);
      console.log(`[migrate-to-r2] Uploaded to R2: ${item.storage_path}`);
      // Build new R2 public URL
      const newUrl = `${R2_PUBLIC_URL}/${item.storage_path}`;
      // Update content column in DB
      const { error: updateError } = await supabase.from('clipboard').update({
        content: newUrl
      }).eq('id', item.id);
      if (updateError) {
        results.push({
          id: item.id,
          status: 'failed',
          reason: `db update failed: ${updateError.message}`
        });
        continue;
      }
      console.log(`[migrate-to-r2] Updated DB for item ${item.id}: ${newUrl}`);
      results.push({
        id: item.id,
        status: 'migrated',
        oldUrl: item.content,
        newUrl
      });
    } catch (e) {
      results.push({
        id: item.id,
        status: 'failed',
        reason: e.message
      });
    }
  }
  const migrated = results.filter((r)=>r.status === 'migrated').length;
  const failed = results.filter((r)=>r.status === 'failed').length;
  const skipped = results.filter((r)=>r.status === 'skipped').length;
  console.log(`[migrate-to-r2] Done. Migrated: ${migrated}, Failed: ${failed}, Skipped: ${skipped}`);
  return new Response(JSON.stringify({
    migrated,
    failed,
    skipped,
    results
  }), {
    status: 200,
    headers: {
      'Content-Type': 'application/json'
    }
  });
});
