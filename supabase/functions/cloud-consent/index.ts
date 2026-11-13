import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { createConsentHandler } from '../_shared/consent_handler.ts';
import { KwsClient } from '../_shared/kws.ts';
import { isSecretKeyCaller, secretKey } from '../_shared/keys.ts';

const env = (name: string) => Deno.env.get(name) ?? '';
const admin = createClient(env('SUPABASE_URL'), secretKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});
let kws: KwsClient | null = null;
try {
  kws = new KwsClient({ clientId: env('KWS_CLIENT_ID'), clientSecret: env('KWS_CLIENT_SECRET'),
    organizationId: env('KWS_ORGANIZATION_ID'), productId: env('KWS_PRODUCT_ID'), apiBaseUrl: env('KWS_API_BASE_URL') });
} catch { /* Disabled until actual UP integration credentials are available. */ }
let webhookSecrets: Record<string, string[]> = {};
try {
  const parsed: unknown = JSON.parse(env('KWS_WEBHOOK_SECRETS') || '{}');
  if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
    for (const [name, values] of Object.entries(parsed)) {
      if (Array.isArray(values) && values.length && values.every((v) => typeof v === 'string' && v.length >= 16)) {
        webhookSecrets[name] = values;
      }
    }
  }
} catch { webhookSecrets = {}; }
Deno.serve(createConsentHandler({
  kws, webhookSecrets, organizationId: env('KWS_ORGANIZATION_ID'), productId: env('KWS_PRODUCT_ID'),
  parentPepper: env('CONSENT_PARENT_HASH_KEY'), parentPortalUrl: env('KWS_PARENT_PORTAL_URL'),
  isMaintenance: (request) => isSecretKeyCaller(request.headers.get('authorization')),
  async operation(action, data = {}) {
    const result = await admin.rpc('consent_service', { p_action: action, p_data: data });
    if (result.error) throw new Error('Consent operation failed');
    return result.data;
  },
  async authenticate(request) {
    const token = request.headers.get('authorization')?.match(/^Bearer ([\w-]+\.[\w-]+\.[\w-]+)$/)?.[1];
    if (!token) return null;
    const { data, error } = await admin.auth.getUser(token);
    return error || !data.user ? null : { id: data.user.id, email: data.user.email,
      emailConfirmed: !data.user.is_anonymous && Boolean(data.user.email_confirmed_at) };
  },
  async deleteUser(id) {
    const { error } = await admin.auth.admin.deleteUser(id);
    if (error) throw new Error('Account deletion failed');
  },
  async exportUser(id, offset) {
    // Ciphertext is exported unchanged. The service never obtains a passphrase.
    const { data, error } = await admin.from('clipboard').select('*').eq('user_id', id)
      .order('id').range(offset, offset + 499);
    if (error) throw new Error('Account export failed');
    const devices = offset === 0 ? await admin.from('devices').select('id,device_name,device_type').eq('user_id', id) : null;
    if (devices?.error) throw new Error('Device export failed');
    return { clips: data, devices: devices?.data, nextOffset: data.length === 500 ? offset + 500 : null,
      note: 'Encrypted content needs the account passphrase. File paths identify separately stored encrypted objects.' };
  },
  async exportFile(id, path) {
    const clip = await admin.from('clipboard').select('id').eq('user_id', id).eq('storage_path', path).limit(1).maybeSingle();
    if (clip.error || !clip.data) throw new Error('File unavailable');
    const result = await admin.functions.invoke('storage-presign', { body: { action: 'download', ownerId: id, path } });
    if (result.error) throw new Error('File export unavailable');
    return result.data;
  },
}));
