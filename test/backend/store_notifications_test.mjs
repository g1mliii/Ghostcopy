import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { after, before, beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { setupConsentDatabase } from './consent_fixture.mjs';
import { appleChain, appleJws, signJws } from './apple_fixture.mjs';

const moduleUrl = (source) => `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source, { mode: 'transform' })).toString('base64')}`;
const read = (path) => readFile(new URL(`../../supabase/functions/_shared/${path}`, import.meta.url), 'utf8');
const storeUrl = moduleUrl(await read('store_notifications.ts'));
const { createStoreNotificationHandler } = await import(storeUrl);
const { createConsentHandler } = await import(moduleUrl((await read('consent_handler.ts'))
  .replace("'./kws.ts'", JSON.stringify(moduleUrl(await read('kws.ts'))))
  .replace("'./store_notifications.ts'", JSON.stringify(storeUrl))));

const db = new PGlite();
const child = '00000000-0000-4000-8000-000000000001';
const pepper = 'a-private-test-only-pepper-at-least-32-characters';
const bundleId = 'com.ghostcopy.ghostcopy';
const appTransactionId = '704289572311430368';
const withdrawn = [];
let chain;
let clock;

const query = async (sql, params = []) => (await db.query(sql, params)).rows;
async function operation(action, data = {}) {
  return (await query('SELECT public.consent_service($1,$2::jsonb) AS value', [action, JSON.stringify(data)]))[0].value;
}
async function storeOperation(action, data) {
  return (await query('SELECT public.store_consent_service($1,$2::jsonb) AS value', [action, JSON.stringify(data)]))[0].value;
}
const consent = createConsentHandler({
  operation, storeOperation, organizationId: 'org', productId: 'product', parentPepper: pepper,
  parentPortalUrl: 'https://family.test.kidswebservices.com/',
  webhookSecrets: Object.fromEntries(['consent:changed', 'consent:deleted', 'settings:effective-values-changed',
    'settings:parent-limits-changed', 'families:user-removed-from-family', 'families:family-group-deleted'].map((n) => [n, ['s']])),
  kws: { async requestConsent() { return crypto.randomUUID(); }, async permissions() { return { cloudSync: true, fileSync: false }; },
    async withdraw() {}, async deleteSubject() {} },
  authenticate: async () => null, isMaintenance: () => false,
  deleteUser: async () => {}, exportUser: async () => ({}), exportFile: async () => ({}),
});
function stores(overrides = {}) {
  return createStoreNotificationHandler({
    verifyApple: (jws) => appleJws.verifyAppleJws(jws, { roots: [chain.root], now: Date.now() }),
    async revoke(store, refHash, signedAt) {
      return storeOperation('revoke', { store, refHash, signedAt: new Date(signedAt).toISOString() });
    },
    async withdraw(id) { withdrawn.push(id); },
    isMaintenance: (request) => request.headers.get('authorization') === 'Bearer secret',
    refPepper: pepper, bundleId, environments: ['Production'], appAppleId: 1234, now: () => clock,
    ...overrides,
  });
}
async function post(handler, path, body, token) {
  const response = await handler(new Request(`https://api.example/store-consent-notifications${path}`, {
    method: 'POST', body: JSON.stringify(body), headers: token ? { authorization: `Bearer ${token}` } : {},
  }));
  return { status: response.status, body: await response.json() };
}
/** Parent setup with a store reference, approved and bound to an account. */
async function boundChild(storeRef) {
  const response = await consent(new Request('https://api.example/cloud-consent', { method: 'POST', body: JSON.stringify({
    action: 'start', parentEmail: 'parent@example.test', age: 13, country: 'US', noticeVersion: '2026-11-12-v3',
    noticeAcknowledged: true, ...(storeRef ? { storeRef } : {}) }) }));
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  const [request] = await query('SELECT id FROM private.parental_consent_requests ORDER BY created_at DESC LIMIT 1');
  await query(`UPDATE private.parental_consent_requests SET status='authorized',cloud_sync=true,approved_at=now(),
    valid_until=now()+interval '15 minutes',bound_user_id=$2 WHERE id=$1`, [request.id, child]);
  await query(`INSERT INTO public.cloud_authorizations(user_id,account_kind,country,notice_version,status,cloud_sync,valid_until)
    VALUES($1,'parent_managed','US','2026-11-12-v3','authorized',true,now()+interval '15 minutes')`, [child]);
  await query(`INSERT INTO public.devices(user_id,fcm_token) VALUES($1,'token')`, [child]);
  return request.id;
}
async function rescind({ transaction = {}, appData = {}, signedDate = Date.now(), type = 'RESCIND_CONSENT' } = {}) {
  const signedAppTransactionInfo = await signJws({ appTransactionId, bundleId, receiptType: 'Production', ...transaction }, chain);
  return signJws({ notificationType: type, notificationUUID: crypto.randomUUID(), version: '2.0', signedDate,
    appData: { appAppleId: 1234, bundleId, environment: 'Production', signedAppTransactionInfo, ...appData } }, chain);
}

before(async () => { await setupConsentDatabase(db); chain = await appleChain(); });
after(() => db.close());
beforeEach(async () => {
  withdrawn.length = 0;
  clock = Date.now() + 1000;
  await db.exec(`TRUNCATE auth.users CASCADE; TRUNCATE private.parental_consent_requests,private.consent_audit,private.consent_rate_limits,private.store_consent_refs CASCADE;
    UPDATE private.cloud_consent_settings SET enforce_all_accounts=true,child_consent_enabled=true;
    INSERT INTO auth.users(id) VALUES('${child}');`);
});

test('setup stores only a keyed hash of the store reference', async () => {
  const id = await boundChild({ store: 'app_store', id: appTransactionId });
  const [ref] = await query('SELECT * FROM private.store_consent_refs');
  assert.equal(ref.request_id, id);
  assert.equal(ref.store, 'app_store');
  assert.match(ref.ref_hash, /^[a-f0-9]{64}$/);
  assert.ok(!JSON.stringify(await query('SELECT * FROM private.store_consent_refs')).includes(appTransactionId));
});

test('an invalid store reference is refused before a parent is contacted', async () => {
  for (const storeRef of [{ store: 'app_store', id: 'x'.repeat(65) }, { store: 'steam', id: '1' }, { store: 'google_play', id: 'a b' }, 'app_store']) {
    const response = await consent(new Request('https://api.example/cloud-consent', { method: 'POST', body: JSON.stringify({
      action: 'start', parentEmail: 'parent@example.test', age: 13, country: 'US', noticeVersion: '2026-11-12-v3',
      noticeAcknowledged: true, storeRef }) }));
    assert.equal(response.status, 400);
  }
  assert.equal((await query('SELECT count(*)::int AS n FROM private.parental_consent_requests'))[0].n, 0);
});

test('RESCIND_CONSENT revokes the bound account the same way a parent withdrawal does', async () => {
  const id = await boundChild({ store: 'app_store', id: appTransactionId });
  const response = await post(stores(), '/apple', { signedPayload: await rescind() });
  assert.deepEqual(response, { status: 200, body: { received: true, revoked: 1 } });
  const [request] = await query('SELECT * FROM private.parental_consent_requests WHERE id=$1', [id]);
  assert.equal(request.status, 'revoked');
  assert.equal(request.requires_new_consent, true);
  const [profile] = await query('SELECT * FROM public.cloud_authorizations WHERE user_id=$1', [child]);
  assert.equal(profile.status, 'revoked');
  assert.equal(profile.cloud_sync, false);
  assert.equal((await query('SELECT fcm_token FROM public.devices'))[0].fcm_token, null);
  assert.deepEqual(withdrawn, [id]);
  assert.deepEqual((await query('SELECT action,verification_method FROM private.consent_audit WHERE request_id=$1 ORDER BY id', [id]))
    .map((row) => row.action), ['parent_withdrew_consent', 'store_withdrew_consent']);
  assert.equal((await operation('access', { userId: child })).allowed, false);
  // Apple retries: a repeat is acknowledged and changes nothing.
  assert.deepEqual((await post(stores(), '/apple', { signedPayload: await rescind() })).body, { received: true, revoked: 0 });
});

test('a withdrawal signed before the reference was bound does not revoke a later consent', async () => {
  await boundChild({ store: 'app_store', id: appTransactionId });
  const response = await post(stores(), '/apple', { signedPayload: await rescind({ signedDate: Date.now() - 3600000 }) });
  assert.equal(response.body.revoked, 0);
  assert.equal((await operation('access', { userId: child })).allowed, true);
});

test('another app transaction, app or environment revokes nothing', async () => {
  await boundChild({ store: 'app_store', id: appTransactionId });
  const cases = [
    [{ transaction: { appTransactionId: '1' } }, 200],
    [{ appData: { bundleId: 'com.example.other' } }, 200],
    [{ appData: { environment: 'Sandbox' } }, 200],
    [{ appData: { appAppleId: 99 } }, 200],
    [{ transaction: { bundleId: 'com.example.other' } }, 400],
    [{ transaction: { receiptType: 'Sandbox' } }, 400],
    [{ type: 'TEST' }, 200],
  ];
  for (const [input, status] of cases) {
    const response = await post(stores(), '/apple', { signedPayload: await rescind(input) });
    assert.equal(response.status, status, JSON.stringify(input));
    assert.ok(!response.body.revoked, JSON.stringify(input));
  }
  assert.equal((await operation('access', { userId: child })).allowed, true);
  assert.deepEqual(withdrawn, []);
});

test('a notification not signed through the pinned root is refused', async () => {
  await boundChild({ store: 'app_store', id: appTransactionId });
  const pinned = chain;
  chain = await appleChain();
  const forged = await rescind();
  chain = pinned;
  assert.equal((await post(stores(), '/apple', { signedPayload: forged })).status, 401);
  assert.equal((await post(stores(), '/apple', {})).status, 400);
  // A genuine notification wrapping a forged app transaction is refused too.
  const inner = await (async () => { const real = chain; chain = await appleChain(); const jws = await signJws({ appTransactionId, bundleId }, chain); chain = real; return jws; })();
  const outer = await signJws({ notificationType: 'RESCIND_CONSENT', signedDate: Date.now(),
    appData: { bundleId, environment: 'Production', signedAppTransactionInfo: inner } }, chain);
  assert.equal((await post(stores(), '/apple', { signedPayload: outer })).status, 401);
  assert.equal((await operation('access', { userId: child })).allowed, true);
});

test('Sandbox notifications are accepted only where configured', async () => {
  await boundChild({ store: 'app_store', id: appTransactionId });
  const signedPayload = await rescind({ appData: { environment: 'Sandbox', appAppleId: undefined }, transaction: { receiptType: 'Sandbox' } });
  assert.equal((await post(stores(), '/apple', { signedPayload })).body.ignored, true);
  assert.equal((await post(stores({ environments: ['Production', 'Sandbox'] }), '/apple', { signedPayload })).body.revoked, 1);
});

test('Play Console revoked install IDs revoke bound requests through the secret-key path', async () => {
  const id = await boundChild({ store: 'google_play', id: 'install-abc_123' });
  const body = { installIds: ['install-abc_123', 'install-unknown'] };
  assert.equal((await post(stores(), '/google-revocations', body)).status, 403);
  assert.equal((await post(stores(), '/google-revocations', body, 'wrong')).status, 403);
  assert.equal((await post(stores(), '/google-revocations', { installIds: ['bad id'] }, 'secret')).status, 400);
  assert.deepEqual(await post(stores(), '/google-revocations', body, 'secret'), { status: 200, body: { revoked: 1 } });
  assert.equal((await operation('access', { userId: child })).allowed, false);
  assert.deepEqual(withdrawn, [id]);
  // An App Store withdrawal with the same identifier value cannot reach a Play binding.
  assert.equal((await query("SELECT count(*)::int AS n FROM private.store_consent_refs WHERE store='app_store'"))[0].n, 0);
});

test('store references go with their request', async () => {
  const id = await boundChild({ store: 'app_store', id: appTransactionId });
  await operation('remove_request', { id });
  assert.equal((await query('SELECT count(*)::int AS n FROM private.store_consent_refs'))[0].n, 0);
});
