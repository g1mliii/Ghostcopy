import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = stripTypeScriptTypes((await readFile(new URL('../../supabase/functions/delete-account/index.ts', import.meta.url), 'utf8'))
  .replace(/^import .*\r?\n/gm, ''));

// A real P-256 key in PKCS#8 PEM, the shape of Apple's .p8, so the signing
// path runs for real and its signature can be checked.
const keyPair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', keyPair.privateKey)).toString('base64');
const applePem = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----`;

function fixture({ user = { id: 'user', identities: [{ provider: 'email' }] }, deleteError = null,
  appleKey = applePem, tokenStatus = 200, revokeStatus = 200 } = {}) {
  let handler;
  const deletedUsers = [];
  const appleCalls = [];
  const client = {
    auth: {
      getUser: async () => (user ? { data: { user }, error: null } : { data: { user: null }, error: new Error('bad jwt') }),
      admin: { deleteUser: async (id) => { deletedUsers.push(id); return { error: deleteError }; } },
    },
  };
  const fetch = async (url, init) => {
    appleCalls.push({ url, form: Object.fromEntries(new URLSearchParams(init.body)) });
    if (url.endsWith('/auth/token')) {
      return { ok: tokenStatus === 200, status: tokenStatus, json: async () => ({ refresh_token: 'apple-refresh' }) };
    }
    return { ok: revokeStatus === 200, status: revokeStatus };
  };
  vm.runInContext(source, vm.createContext({
    console: { error() {}, log() {} }, Date, Math, JSON, Uint8Array, String, TextEncoder, URLSearchParams,
    atob, btoa, crypto, fetch,
    createClient: () => client,
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (key) => ({ APPLE_PRIVATE_KEY: appleKey, SUPABASE_SERVICE_ROLE_KEY: 'service-key' })[key] ?? '' },
      serve: (callback) => { handler = callback; },
    },
  }));
  return {
    deletedUsers, appleCalls,
    request: (body = {}, method = 'POST') => handler({
      method, headers: new Headers({ Authorization: 'Bearer user-token' }), json: async () => body,
    }),
  };
}

// Objects made inside the vm have another realm's prototype, which strict
// equality counts as a difference; compare their JSON instead.
const plain = (value) => JSON.parse(JSON.stringify(value));

async function verifyClientSecret(jwt) {
  const [header, payload, signature] = jwt.split('.');
  const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString());
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, keyPair.publicKey,
    Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${payload}`));
  return { header: decode(header), payload: decode(payload), valid };
}

test('deletes the caller and nothing else is asked of an email account', async () => {
  const f = fixture();
  const response = await f.request();
  assert.equal(response.status, 200);
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: null });
  assert.deepEqual(f.deletedUsers, ['user']);
  assert.equal(f.appleCalls.length, 0);
});

test('the account deleted is the one in the session, whatever the body says', async () => {
  const f = fixture();
  await f.request({ user_id: 'someone-else' });
  assert.deepEqual(f.deletedUsers, ['user']);
});

test('no valid session deletes nothing', async () => {
  const f = fixture({ user: null });
  assert.equal((await f.request()).status, 401);
  assert.equal(f.deletedUsers.length, 0);
});

test('only POST deletes', async () => {
  const f = fixture();
  assert.equal((await f.request({}, 'GET')).status, 405);
  assert.equal(f.deletedUsers.length, 0);
});

test('an Apple account has its Apple token exchanged and revoked, then is deleted', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple' }] } });
  const response = await f.request({ apple_authorization_code: 'fresh-code' });

  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: true });
  assert.deepEqual(f.deletedUsers, ['user']);
  const [exchange, revoke] = f.appleCalls;
  assert.equal(exchange.url, 'https://appleid.apple.com/auth/token');
  assert.equal(exchange.form.code, 'fresh-code');
  assert.equal(exchange.form.client_id, 'com.ghostcopy.ghostcopy');
  assert.equal(revoke.url, 'https://appleid.apple.com/auth/revoke');
  assert.equal(revoke.form.token, 'apple-refresh');
  assert.equal(revoke.form.token_type_hint, 'refresh_token');

  const secret = await verifyClientSecret(exchange.form.client_secret);
  assert.ok(secret.valid, 'client secret must verify against the key');
  assert.deepEqual(secret.header, { alg: 'ES256', kid: 'Y8NRLTKXG3' });
  assert.equal(secret.payload.iss, 'R9TKT8U45R');
  assert.equal(secret.payload.sub, 'com.ghostcopy.ghostcopy');
  assert.equal(secret.payload.aud, 'https://appleid.apple.com');
  assert.ok(secret.payload.exp - secret.payload.iat <= 300);
});

test('a failed Apple revocation is reported but does not keep the data', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple' }] }, revokeStatus: 400 });
  const response = await f.request({ apple_authorization_code: 'fresh-code' });
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.deepEqual(f.deletedUsers, ['user']);
});

test('an Apple account deleted without a code is still deleted, flagged unrevoked', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple' }] } });
  const response = await f.request();
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.equal(f.appleCalls.length, 0);
});

test('a failed delete says so', async () => {
  const f = fixture({ deleteError: new Error('db down') });
  assert.equal((await f.request()).status, 500);
});
