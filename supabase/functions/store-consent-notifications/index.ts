import 'jsr:@supabase/functions-js@2/edge-runtime.d.ts';
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { appleRootCaG3, verifyAppleJws } from '../_shared/apple_jws.ts';
import { KwsClient } from '../_shared/kws.ts';
import { isSecretKeyCaller, secretKey } from '../_shared/keys.ts';
import { createStoreNotificationHandler } from '../_shared/store_notifications.ts';

// App Store Connect > App > App Information > App Store Server Notifications
// points its Production (and, for testing, Sandbox) URL at
// <project>/functions/v1/store-consent-notifications/apple.
const env = (name: string) => Deno.env.get(name) ?? '';
const admin = createClient(env('SUPABASE_URL'), secretKey(), {
  auth: { persistSession: false, autoRefreshToken: false },
});
let kws: KwsClient | null = null;
try {
  kws = new KwsClient({ clientId: env('KWS_CLIENT_ID'), clientSecret: env('KWS_CLIENT_SECRET'),
    organizationId: env('KWS_ORGANIZATION_ID'), productId: env('KWS_PRODUCT_ID'), apiBaseUrl: env('KWS_API_BASE_URL') });
} catch { /* Local revocation still applies without provider credentials. */ }
const appAppleId = Number(env('APPLE_APP_APPLE_ID'));

Deno.serve(createStoreNotificationHandler({
  verifyApple: (jws) => verifyAppleJws(jws, { roots: [appleRootCaG3], now: Date.now() }),
  async revoke(store, refHash, signedAt) {
    const result = await admin.rpc('store_consent_service', {
      p_action: 'revoke', p_data: { store, refHash, signedAt: new Date(signedAt).toISOString() },
    });
    if (result.error) throw new Error('Store revocation failed');
    return Array.isArray(result.data) ? result.data.map(String) : [];
  },
  async withdraw(id) { await kws?.withdraw(id); },
  isMaintenance: (request) => isSecretKeyCaller(request.headers.get('authorization')),
  // Same key as the consent function, so both compute the same reference hash.
  refPepper: env('CONSENT_PARENT_HASH_KEY'),
  // The iOS Runner's PRODUCT_BUNDLE_IDENTIFIER.
  bundleId: env('APPLE_BUNDLE_ID') || 'com.ghostcopy.ghostcopy',
  environments: (env('APPLE_NOTIFICATION_ENVIRONMENTS') || 'Production').split(',').map((v) => v.trim()),
  appAppleId: Number.isSafeInteger(appAppleId) && appAppleId > 0 ? appAppleId : undefined,
}));
