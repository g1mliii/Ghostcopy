import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';

const compiled = stripTypeScriptTypes(
  await readFile(new URL('../../supabase/functions/_shared/kws.ts', import.meta.url), 'utf8'),
  { mode: 'transform' },
);
const { KwsClient, verifyKwsSignature, validatedKwsBase } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`
);
const now = Date.UTC(2026, 10, 12);
const raw = new TextEncoder().encode('{ "name": "consent:changed", "payload": {} }');

async function signature(secret, timestamp = String(now), bytes = raw) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signed = new Uint8Array([...new TextEncoder().encode(`${timestamp}.`), ...bytes]);
  const hex = Buffer.from(await crypto.subtle.sign('HMAC', key, signed)).toString('hex');
  return `t=${timestamp},v1=${hex}`;
}

test('KWS signatures cover raw bytes, tolerate rotation and reject replay', async () => {
  const header = await signature('new-key');
  assert.equal(await verifyKwsSignature(raw, header, ['old-key', 'new-key'], now), true);
  assert.equal(await verifyKwsSignature(raw, header, ['wrong-key'], now), false);
  assert.equal(await verifyKwsSignature(new TextEncoder().encode(JSON.stringify(JSON.parse(
    new TextDecoder().decode(raw)))), header, ['new-key'], now), false);
  assert.equal(await verifyKwsSignature(raw, header, ['new-key'], now + 300001), false);
  assert.equal(await verifyKwsSignature(raw, header, ['new-key'], now - 300001), false);
  assert.equal(await verifyKwsSignature(raw, `${await signature('old-key')},v1=${header.split('v1=')[1]}`,
    ['new-key'], now), true);
  assert.equal(await verifyKwsSignature(raw, await signature('new-key', String(now / 1000)),
    ['new-key'], now), true);
  for (const invalid of [null, '', `${header},t=${now}`, `${header},v1=bad`, `${header},bogus=x`]) {
    assert.equal(await verifyKwsSignature(raw, invalid, ['new-key'], now), false);
  }
});

const config = {
  clientId: 'client', clientSecret: 'secret', productId: 'product',
  organizationId: 'org', apiBaseUrl: 'https://api.kidswebservices.com',
};
const permission = (name, overrides = {}) => ({ namespace: 'ghostcopy', settingName: name,
  parentLimitUpdatedAt: now,
  effectiveValue: true, parentLimit: true, definition: { ageBracket: { consentType: 'opt-in-vpc' } },
  ...overrides });
function fixture({ settings = [permission('cloudSync'), permission('fileSync')], unauthorizedOnce = false,
  error = false } = {}) {
  const calls = [];
  let tokenCount = 0;
  const client = new KwsClient(config, async (url, init) => {
    calls.push({ url: String(url), ...init });
    if (String(url).includes('/openid-connect/token')) {
      tokenCount++;
      return Response.json({ access_token: `developer-token-${tokenCount}`, expires_in: 3600 });
    }
    if (unauthorizedOnce) { unauthorizedOnce = false; return new Response(null, { status: 401 }); }
    if (error) return new Response('private provider details', { status: 503 });
    if (init.method === 'DELETE') return new Response(null, { status: 204 });
    if (String(url).endsWith('/send-consent-email')) {
      return Response.json({ response: { consentRequestId: 'request-id' } });
    }
    return Response.json({ response: { settings } });
  }, () => now);
  return { client, calls };
}

test('KWS consent request sends minimal documented fields and server-only credentials', async () => {
  const { client, calls } = fixture();
  assert.equal(await client.requestConsent({ consenteeId: 'opaque-child', parentEmail: 'parent@example.com',
    age: 8, location: 'CA' }), 'request-id');
  const auth = calls[0];
  assert.equal(auth.headers.Authorization, `Basic ${btoa('client:secret')}`);
  assert.equal(new URLSearchParams(auth.body).get('scope'), 'settings consent family');
  const call = calls[1];
  assert.equal(call.url, 'https://api.kidswebservices.com/v1/settings/admin/users/opaque-child/products/product/send-consent-email');
  const body = JSON.parse(call.body);
  assert.equal(body.enforceParentalControl, true);
  assert.equal(body.ageProvidedAt, now / 1000);
  assert.equal(body.age, 8);
  assert.equal(body.parentEmail, 'parent@example.com');
  assert.equal('dob' in body, false);
  assert.deepEqual(body.settings, [{ namespace: 'ghostcopy', settingName: 'cloudSync' },
    { namespace: 'ghostcopy', settingName: 'fileSync' }]);
  assert.equal(call.headers['User-Agent'], 'GhostCopy-Consent/1.0');
});

test('permission grants require VPC, actual parent limits and effective values', async () => {
  for (const denied of [
    { effectiveValue: false }, { effectiveValue: 'true' }, { parentLimit: false },
    { definition: { ageBracket: { consentType: 'opt-in-unverified' } } },
    { definition: {} },
    { parentLimitUpdatedAt: null }, { parentLimitUpdatedAt: now + 300001 },
  ]) {
    const { client } = fixture({ settings: [permission('cloudSync', denied), permission('fileSync')] });
    assert.deepEqual(await client.permissions('child'), { cloudSync: false, fileSync: true });
  }
  const { client, calls } = fixture();
  assert.deepEqual(await client.permissions('child'), { cloudSync: true, fileSync: true });
  assert.equal(calls[1].url, 'https://api.kidswebservices.com/v1/settings/users/child/products/product/values?namespace=ghostcopy&format=full');
  await client.permissions('child');
  assert.equal(calls.filter((call) => call.url.includes('/openid-connect/token')).length, 1);
  assert.deepEqual(await client.permissions('child', now + 1), { cloudSync: false, fileSync: false });
  assert.equal((await fixture({ settings: [permission('cloudSync', {
    definition: { ageBracket: { consentType: 'opt-in-verified' } },
  })] }).client.permissions('child')).cloudSync, true);
});

test('missing or duplicate settings fail closed rather than taking the last value', async () => {
  for (const settings of [[], [permission('fileSync')], [permission('cloudSync'), permission('cloudSync')]]) {
    await assert.rejects(fixture({ settings }).client.permissions('child'), /unavailable/);
  }
});

test('a file denial timestamp prevents a stale grant while text remains available', async () => {
  const { client } = fixture();
  assert.deepEqual(await client.permissions('child', 0, now + 1), { cloudSync: true, fileSync: false });
});

test('withdrawal uses the documented settings object for each purpose', async () => {
  const { client, calls } = fixture();
  await client.withdraw('child');
  assert.deepEqual(calls.slice(1).map((call) => ({ method: call.method, body: JSON.parse(call.body) })), [
    { method: 'PATCH', body: { settings: { namespace: 'ghostcopy', settingName: 'cloudSync', parentLimit: false } } },
    { method: 'PATCH', body: { settings: { namespace: 'ghostcopy', settingName: 'fileSync', parentLimit: false } } },
  ]);
});

test('a 401 refreshes credentials once; other failures are sanitized and not retried', async () => {
  const { client, calls } = fixture({ unauthorizedOnce: true });
  await client.permissions('child');
  assert.equal(calls.filter((call) => call.url.includes('/openid-connect/token')).length, 2);
  const failed = fixture({ error: true });
  await assert.rejects(failed.client.requestConsent({ consenteeId: 'child', parentEmail: 'parent@example.com',
    age: 8, location: 'US' }), (error) => !error.message.includes('private provider details'));
  assert.equal(failed.calls.length, 2);
});

test('provider erasure removes all subject data, not just product preferences; hosts are constrained', async () => {
  const { client, calls } = fixture();
  await client.deleteSubject('child');
  assert.equal(calls[1].method, 'DELETE');
  assert.equal(calls[1].url, 'https://api.kidswebservices.com/v1/settings/admin/users/child/values');
  for (const url of ['http://api.kidswebservices.com', 'https://example.com',
    'https://api.kidswebservices.com.evil.example', 'https://secret@api.kidswebservices.com',
    'https://api.kidswebservices.com/other', 'https://api.kidswebservices.com/?x=y']) {
    assert.throws(() => validatedKwsBase(url));
  }
});
