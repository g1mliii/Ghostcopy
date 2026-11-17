import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { before, after, beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { setupConsentDatabase } from './consent_fixture.mjs';

const moduleUrl = (source) => `data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source, { mode: 'transform' })).toString('base64')}`;
const kwsUrl = moduleUrl(await readFile(new URL('../../supabase/functions/_shared/kws.ts', import.meta.url), 'utf8'));
const storeUrl = moduleUrl(await readFile(new URL('../../supabase/functions/_shared/store_notifications.ts', import.meta.url), 'utf8'));
const { createConsentHandler } = await import(moduleUrl((await readFile(
  new URL('../../supabase/functions/_shared/consent_handler.ts', import.meta.url), 'utf8'))
  .replace("'./kws.ts'", JSON.stringify(kwsUrl)).replace("'./store_notifications.ts'", JSON.stringify(storeUrl))));
const db = new PGlite();
const user = '00000000-0000-4000-8000-000000000001';
const other = '00000000-0000-4000-8000-000000000002';
const organizationId = 'test-org'; const productId = 'test-product';
const webhookNames = ['consent:changed', 'consent:deleted', 'settings:effective-values-changed',
  'settings:parent-limits-changed', 'families:user-removed-from-family', 'families:family-group-deleted'];
const webhookSecrets = Object.fromEntries(webhookNames.map((name) => [name, [`secret:${name}`]]));
let granted; let files; let available; let configurationComplete; let permissionTimes;
const calls = []; const erased = []; const exports = [];
async function operation(action, data = {}) {
  return (await db.query('SELECT public.consent_service($1,$2::jsonb) AS value', [action, JSON.stringify(data)])).rows[0].value;
}
async function storeOperation(action, data) {
  return (await db.query('SELECT public.store_consent_service($1,$2::jsonb) AS value', [action, JSON.stringify(data)])).rows[0].value;
}
function handler() {
  return createConsentHandler({
    operation, storeOperation, organizationId, productId,
    parentPepper: 'a-private-test-only-pepper-at-least-32-characters',
    parentPortalUrl: configurationComplete ? 'https://family.test.kidswebservices.com/' : '',
    webhookSecrets,
    kws: {
      async requestConsent(input) { calls.push(input); if (!available) throw new Error('Provider unavailable'); return crypto.randomUUID(); },
      async permissions() { if (!available) throw new Error('Provider unavailable'); return { cloudSync: granted, fileSync: files, ...permissionTimes }; },
      async withdraw(id) { calls.push({ withdrew: id }); },
      async deleteSubject(id) { erased.push(id); },
    },
    async authenticate(request) {
      const bearer = request.headers.get('authorization');
      return bearer === 'Bearer child' ? { id: user, emailConfirmed: false } : bearer === 'Bearer other' ? { id: other, emailConfirmed: false }
        : bearer === 'Bearer parent' ? { id: other, email: 'Parent@Example.test', emailConfirmed: true }
          : bearer === 'Bearer stranger' ? { id: other, email: 'stranger@example.test', emailConfirmed: true }
            : bearer === 'Bearer unverified' ? { id: other, email: 'parent@example.test', emailConfirmed: false } : null;
    },
    isMaintenance: (request) => request.headers.get('authorization') === 'Bearer maintenance',
    async deleteUser(id) { await db.query('DELETE FROM auth.users WHERE id=$1', [id]); },
    async exportUser(id, offset) { exports.push({ id, offset }); return { clips: [], nextOffset: null }; },
    async exportFile(id, path) { return { id, path, downloadUrl: 'https://test.r2.cloudflarestorage.com/file' }; },
  });
}
async function request(body, token, path = '') {
  const response = await handler()(new Request(`https://api.example/cloud-consent${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body),
  }));
  return { status: response.status, body: await response.json() };
}
const start = () => request({ action: 'start', parentEmail: 'parent@example.test', age: 8, country: 'CA', noticeVersion: '2026-11-12-v3', noticeAcknowledged: true });
before(async () => setupConsentDatabase(db));
after(() => db.close());
beforeEach(async () => {
  granted = false; files = false; available = true; configurationComplete = true;
  permissionTimes = {};
  calls.length = 0; erased.length = 0; exports.length = 0;
  await db.exec(`TRUNCATE auth.users CASCADE; TRUNCATE private.parental_consent_requests,private.consent_events,private.consent_audit,private.consent_rate_limits,private.kws_deletion_queue CASCADE;
    UPDATE private.cloud_consent_settings SET enforce_all_accounts=true,child_consent_enabled=true;
    INSERT INTO auth.users(id) VALUES('${user}'),('${other}');`);
});
async function approved() {
  const response = await start(); assert.equal(response.status, 200);
  granted = true; files = true;
  const poll = await request({ action: 'poll', claimToken: response.body.claimToken });
  assert.equal(poll.body.status, 'authorized');
  assert.equal(poll.body.hasAccount, false);
  return response.body;
}

test('pre-auth request minimizes data, persists only hashes, and cannot bind pending permission', async () => {
  const response = await start(); assert.equal(response.status, 200);
  assert.match(response.body.claimToken, /^[a-f0-9]{64}$/);
  assert.equal(response.body.status, 'pending');
  const stored = (await db.query('SELECT * FROM private.parental_consent_requests')).rows[0];
  assert.notEqual(stored.claim_hash, response.body.claimToken);
  assert.ok(!JSON.stringify(stored).includes('parent@example.test'));
  assert.ok(!JSON.stringify(response.body).includes('parent_hash'));
  assert.ok(!('dateOfBirth' in calls[0]));
  assert.equal((await request({ action: 'authorize', claimToken: response.body.claimToken, userId: other }, 'child')).status, 403);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM public.cloud_authorizations')).rows[0].n, 0);
});

test('both published parent portal origins receive CORS on preflight, success and errors', async () => {
  for (const origin of ['https://ghostcopy.app', 'https://www.ghostcopy.app', 'https://untrusted.example']) {
    for (const [method, body, status] of [
      ['OPTIONS', undefined, 200],
      ['POST', JSON.stringify({ action: 'parent-list' }), 200],
      ['POST', '{', 400],
    ]) {
      const response = await handler()(new Request('https://api.example/cloud-consent', {
        method, body, headers: { Origin: origin, Authorization: 'Bearer parent',
          'Content-Type': 'application/json', 'Access-Control-Request-Headers': 'authorization,content-type' },
      }));
      assert.equal(response.status, status);
      assert.equal(response.headers.get('Access-Control-Allow-Origin'), origin.endsWith('ghostcopy.app') ? origin : null);
      assert.equal(response.headers.get('Vary'), 'Origin');
      assert.match(response.headers.get('Access-Control-Allow-Headers'), /authorization/);
    }
  }
});

test('cancelling an unbound request invalidates the claim, queues provider erasure and permits a corrected email', async () => {
  const original = await start();
  const id = (await db.query('SELECT id FROM private.parental_consent_requests')).rows[0].id;
  assert.equal((await request({ action: 'cancel', claimToken: 'f'.repeat(64) })).status, 403);
  assert.equal((await request({ action: 'cancel', claimToken: original.body.claimToken })).status, 200);
  assert.equal((await operation('lookup', { id })), null);
  assert.equal((await request({ action: 'poll', claimToken: original.body.claimToken })).status, 403);
  assert.equal((await db.query('SELECT subject_id FROM private.kws_deletion_queue')).rows[0].subject_id, id);
  const replacement = await request({ action: 'start', parentEmail: 'corrected@example.test', age: 8,
    country: 'CA', noticeVersion: '2026-11-12-v3', noticeAcknowledged: true });
  assert.equal(replacement.status, 200);
  assert.notEqual(replacement.body.claimToken, original.body.claimToken);
  assert.equal(calls.at(-1).parentEmail, 'corrected@example.test');
});

test('cancellation cannot delete a bound account or bypass existing request rate limits', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  const proof = (await request({ action: 'authorize' }, 'child')).body.deviceClaim;
  for (const claimToken of [approval.claimToken, proof]) {
    assert.equal((await request({ action: 'cancel', claimToken })).status, 409);
  }
  assert.equal((await operation('lookup', { userId: user })).bound_user_id, user);
  assert.equal((await operation('profile', { userId: user })).status, 'authorized');
  for (let i = 0; i < 3; i++) {
    const pending = await start();
    assert.equal(pending.status, 200);
    assert.equal((await request({ action: 'cancel', claimToken: pending.body.claimToken })).status, 200);
  }
  assert.equal((await start()).status, 503);
  assert.equal(calls.length, 4);
});

test('an authorized account reaching adulthood graduates only after adult acknowledgement', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  await db.exec(`UPDATE private.parental_consent_requests SET age=17,created_at=now()-interval '1 year 1 day'
    WHERE bound_user_id='${user}';`);
  const poll = await request({ action: 'poll', claimToken: approval.claimToken });
  assert.equal(poll.body.status, 'authorized');
  assert.equal(poll.body.independentEligible, true);
  assert.equal((await operation('profile', { userId: user })).account_kind, 'parent_managed');
  const data = { action: 'authorize', graduate: true, age: 18, country: 'CA',
    noticeVersion: '2026-11-12-v3', termsAccepted: true, privacyAcknowledged: true };
  assert.equal((await request({ ...data, termsAccepted: false }, 'child')).status, 503);
  const adult = await request(data, 'child');
  assert.equal(adult.body.allowed, true);
  assert.equal(adult.body.accountKind, 'adult');
  assert.deepEqual((await request({ action: 'parent-list' }, 'parent')).body.children, []);
});
test('current approval binds only the authenticated subject and is not reusable by a second user', async () => {
  const approval = await approved();
  const result = await request({ action: 'authorize', claimToken: approval.claimToken, userId: other }, 'child');
  assert.equal(result.body.allowed, true); assert.equal(result.body.accountKind, 'parent_managed');
  const recovery = await request({ action: 'poll', claimToken: approval.claimToken });
  assert.equal(recovery.body.hasAccount, true);
  assert.ok(!('bound_user_id' in recovery.body));
  assert.ok(!('refresh_token' in recovery.body));
  assert.equal((await request({ action: 'authorize', claimToken: approval.claimToken }, 'other')).status, 503);
  assert.equal((await operation('profile', { userId: other })), null);
  const pretendAdult = await request({ action: 'authorize', age: 18, country: 'CA', noticeVersion: '2026-11-12-v3', termsAccepted: true, privacyAcknowledged: true }, 'child');
  assert.equal(pretendAdult.body.accountKind, 'parent_managed');
});
test('unavailable configuration, notice omissions and provider failure never activate a child', async () => {
  configurationComplete = false;
  assert.equal((await request({ action: 'configuration' })).body.childrenEnabled, false);
  assert.equal((await start()).status, 503);
  configurationComplete = true;
  assert.equal((await request({ action: 'start', age: 8, country: 'CA', parentEmail: 'parent@example.test' })).status, 400);
  available = false;
  assert.equal((await start()).status, 503);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM private.parental_consent_requests')).rows[0].n, 0);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM private.kws_deletion_queue')).rows[0].n, 1);
});
test('only the verified original parent may export, withdraw or delete; revocation wins over outages', async () => {
  const approval = await approved(); await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  const list = (await request({ action: 'parent-list' }, 'parent')).body.children;
  assert.equal(list.length, 1); const id = list[0].id;
  assert.deepEqual((await request({ action: 'parent-list' }, 'stranger')).body.children, []);
  assert.equal((await request({ action: 'parent-export', id }, 'unverified')).status, 403);
  assert.equal((await request({ action: 'parent-export', id }, 'stranger')).status, 404);
  assert.equal((await request({ action: 'parent-export', id, offset: 500 }, 'parent')).status, 200);
  assert.deepEqual(exports, [{ id: user, offset: 500 }]);
  assert.equal((await request({ action: 'parent-delete', id }, 'parent')).status, 400);
  assert.equal((await request({ action: 'parent-revoke', id, confirm: true }, 'parent')).status, 200);
  available = false;
  assert.equal((await request({ action: 'status' }, 'child')).body.allowed, false);
  assert.equal((await request({ action: 'parent-delete', id, confirm: true }, 'parent')).status, 200);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM auth.users WHERE id=$1', [user])).rows[0].n, 0);
  assert.equal((await request({ action: 'maintenance' }, 'parent')).status, 403);
  available = true;
  assert.equal((await request({ action: 'maintenance' }, 'maintenance')).body.deleted, 1);
  assert.deepEqual(erased, [id]);
});
async function webhook(event, secret) {
  const raw = JSON.stringify(event); const time = String(Date.now());
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = Buffer.from(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${time}.${raw}`))).toString('hex');
  return handler()(new Request('https://api.example/cloud-consent/webhook', { method: 'POST', body: raw, headers: { 'x-kws-signature': `t=${time},v1=${signature}` } }));
}

async function refreshBound() {
  await db.query("UPDATE private.parental_consent_requests SET valid_until=now()-interval '1 minute',last_checked_at=now()-interval '1 minute' WHERE bound_user_id=$1", [user]);
  return request({ action: 'status' }, 'child');
}
const denial = (id, time, settings) => ({ name: 'settings:parent-limits-changed',
  orgId: organizationId, productId, time: new Date(time).toISOString(),
  payload: { userId: id, settings: settings.map((settingName) => ({ namespace: 'ghostcopy', settingName, parentLimit: false })) } });
async function pushDevice() {
  await db.query("INSERT INTO public.devices(user_id,fcm_token,wns_channel_uri) VALUES($1,'push','wns')", [user]);
}
async function assertPush(expected) {
  assert.deepEqual((await db.query('SELECT fcm_token,wns_channel_uri FROM public.devices WHERE user_id=$1', [user])).rows[0],
    { fcm_token: expected ? 'push' : null, wns_channel_uri: expected ? 'wns' : null });
}

test('a delayed cloud denial cannot override a later observed provider grant; a newer denial still wins', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  await pushDevice();
  const id = (await operation('lookup', { userId: user })).id;
  const grantTime = Date.now();
  permissionTimes = { cloudGrantedAt: grantTime, fileGrantedAt: grantTime - 30000 };
  assert.equal((await refreshBound()).body.allowed, true);
  assert.equal((await webhook(denial(id, grantTime - 10000, ['cloudSync']), 'secret:settings:parent-limits-changed')).status, 200);
  assert.equal((await operation('profile', { userId: user })).status, 'authorized');
  assert.equal((await operation('lookup', { userId: user })).requires_new_consent, false);
  await assertPush(true);
  assert.equal((await webhook(denial(id, grantTime + 1000, ['cloudSync']), 'secret:settings:parent-limits-changed')).status, 200);
  assert.equal((await operation('profile', { userId: user })).status, 'revoked');
  await assertPush(false);
  assert.equal((await refreshBound()).body.allowed, false); // Stale provider grant cannot resurrect it.
});

test('a newer file grant cannot hide a current cloud denial or a family unlink', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  const id = (await operation('lookup', { userId: user })).id;
  const grantTime = Date.now();
  permissionTimes = { cloudGrantedAt: grantTime - 20000, fileGrantedAt: grantTime };
  await refreshBound();
  await webhook(denial(id, grantTime - 10000, ['cloudSync']), 'secret:settings:parent-limits-changed');
  assert.equal((await operation('lookup', { userId: user })).requires_new_consent, true);
  await webhook({ name: 'families:user-removed-from-family', orgId: organizationId, productId,
    time: new Date(grantTime - 5000).toISOString(), payload: { userId: id } }, 'secret:families:user-removed-from-family');
  assert.equal((await operation('lookup', { userId: user })).parent_can_manage, false);
});

test('mixed old cloud and current file denials preserve cloud permission and push registrations', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  await pushDevice();
  const id = (await operation('lookup', { userId: user })).id;
  const grantTime = Date.now();
  permissionTimes = { cloudGrantedAt: grantTime, fileGrantedAt: grantTime - 30000 };
  await refreshBound();
  files = false;
  await webhook(denial(id, grantTime - 10000, ['cloudSync', 'fileSync']), 'secret:settings:parent-limits-changed');
  const profile = await operation('profile', { userId: user });
  assert.equal(profile.status, 'authorized');
  assert.equal(profile.cloud_sync, true);
  assert.equal(profile.file_sync, false);
  assert.equal((await operation('lookup', { userId: user })).requires_new_consent, false);
  await assertPush(true);
});

test('effective-value refresh preserves push until the provider actually denies cloud access', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  await pushDevice();
  const id = (await operation('lookup', { userId: user })).id;
  const event = { name: 'settings:effective-values-changed', orgId: organizationId, productId,
    time: new Date().toISOString(), payload: { userId: id, settings: [] } };
  await webhook(event, 'secret:settings:effective-values-changed');
  assert.equal((await operation('profile', { userId: user })).status, 'authorized');
  await assertPush(true);
  granted = false;
  event.time = new Date(Date.now() + 1000).toISOString();
  await webhook(event, 'secret:settings:effective-values-changed');
  assert.equal((await operation('profile', { userId: user })).status, 'revoked');
  await assertPush(false);
});
test('signed denial revokes despite stale provider reads; wrong event secret and product cannot act', async () => {
  const approval = await approved(); await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  const child = (await request({ action: 'parent-list' }, 'parent')).body.children[0];
  const event = { name: 'settings:parent-limits-changed', orgId: organizationId, productId,
    time: new Date().toISOString(), payload: { userId: child.id, settings: [{ namespace: 'ghostcopy', settingName: 'cloudSync', parentLimit: false }] } };
  assert.equal((await webhook(event, 'secret:consent:changed')).status, 403);
  assert.equal((await webhook({ ...event, productId: 'other' }, 'secret:settings:parent-limits-changed')).status, 403);
  assert.equal((await operation('profile', { userId: user })).status, 'authorized');
  assert.equal((await webhook(event, 'secret:settings:parent-limits-changed')).status, 200);
  assert.equal((await operation('profile', { userId: user })).status, 'revoked');
  assert.equal((await webhook(event, 'secret:settings:parent-limits-changed')).status, 200);
  assert.equal((await request({ action: 'status' }, 'child')).body.allowed, false);
});
test('oversized bodies and unsigned webhooks stop before account operations', async () => {
  assert.equal((await handler()(new Request('https://api.example/cloud-consent', { method: 'POST', body: 'x'.repeat(65537) }))).status, 413);
  assert.equal((await request({}, undefined, '/webhook')).status, 401);
});

test('a refreshed device proof restores its existing profile without rebinding', async () => {
  const approval = await approved();
  await request({ action: 'authorize', claimToken: approval.claimToken }, 'child');
  const linked = await request({ action: 'authorize' }, 'child');
  assert.match(linked.body.deviceClaim, /^device\.v1\./);
  await db.exec(`UPDATE private.parental_consent_requests SET status='pending',cloud_sync=false,
    valid_until=now()-interval '1 minute',last_checked_at=now()-interval '1 minute'
    WHERE bound_user_id='${user}';
    UPDATE public.cloud_authorizations SET status='revoked',cloud_sync=false,
    valid_until=now()-interval '1 minute' WHERE user_id='${user}';`);
  const recovered = await request({ action: 'authorize', claimToken: linked.body.deviceClaim }, 'child');
  assert.equal(recovered.status, 200);
  assert.equal(recovered.body.allowed, true);
  assert.equal(recovered.body.accountKind, 'parent_managed');
  assert.equal((await operation('lookup', { userId: user })).bound_user_id, user);
  assert.equal((await request({ action: 'authorize', claimToken: linked.body.deviceClaim }, 'other')).status, 503);
});

test('a QR-linked child gets a scoped pre-auth device proof, never a new-account binding capability', async () => {
  const approval = await approved();
  await request({action:'authorize',claimToken:approval.claimToken},'child');
  const linked = await request({action:'authorize',age:18,country:'CA',noticeVersion:'2026-11-12-v3',termsAccepted:true,privacyAcknowledged:true},'child');
  assert.match(linked.body.deviceClaim,/^device\.v1\./);
  assert.equal((await request({action:'poll',claimToken:linked.body.deviceClaim})).body.status,'authorized');
  assert.equal((await request({action:'poll',claimToken:linked.body.deviceClaim.slice(0,-1)+'x'})).status,403);
  const parts = linked.body.deviceClaim.split('.');
  parts[2] = parts[2].replace(/[A-Za-z]/, (character) => character === character.toUpperCase() ? character.toLowerCase() : character.toUpperCase());
  assert.equal((await request({action:'poll',claimToken:parts.join('.')})).status,403);
  assert.equal((await request({action:'authorize',claimToken:linked.body.deviceClaim},'other')).status,503);
  const id = (await request({action:'parent-list'},'parent')).body.children[0].id;
  await request({action:'parent-revoke',id,confirm:true},'parent');
  assert.equal((await request({action:'poll',claimToken:linked.body.deviceClaim})).body.status,'revoked');
});
