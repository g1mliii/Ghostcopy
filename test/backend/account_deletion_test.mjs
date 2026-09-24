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
  appleKey = applePem, tokenStatus = 200, revokeStatus = 200, codeSubject = 'apple-sub', appleHangs = false } = {}) {
  let handler;
  const deletedUsers = [];
  const appleCalls = [];
  const timeouts = [];
  const client = {
    auth: {
      getUser: async () => (user ? { data: { user }, error: null } : { data: { user: null }, error: new Error('bad jwt') }),
      admin: { deleteUser: async (id) => { deletedUsers.push(id); return { error: deleteError }; } },
    },
  };
  const fetch = async (url, init) => {
    appleCalls.push({ url, form: Object.fromEntries(new URLSearchParams(init.body)), deletedYet: deletedUsers.length > 0 });
    if (appleHangs) {
      // Never answers; only the abort signal ends it.
      return new Promise((_, reject) => init.signal?.addEventListener('abort', () => reject(init.signal.reason)));
    }
    if (url.endsWith('/auth/token')) {
      // The id_token names the Apple ID the code was issued for.
      const idToken = ['e30', Buffer.from(JSON.stringify({ sub: codeSubject })).toString('base64url'), 'sig'].join('.');
      return { ok: tokenStatus === 200, status: tokenStatus,
        json: async () => ({ refresh_token: 'apple-refresh', id_token: idToken }) };
    }
    return { ok: revokeStatus === 200, status: revokeStatus };
  };
  vm.runInContext(source, vm.createContext({
    console: { error() {}, log() {} }, Date, Math, JSON, Uint8Array, String, TextEncoder, URLSearchParams,
    atob, btoa, crypto, fetch,
    // The function's timeouts are recorded and shortened, so a hung Apple call
    // is tested without waiting it out.
    AbortSignal: {
      timeout: (ms) => {
        timeouts.push(ms);
        // Not AbortSignal.timeout(1): its timer is unref'd, so the test
        // process would exit while the hung fetch is still waiting on it.
        const controller = new AbortController();
        setTimeout(() => controller.abort(new DOMException('timed out', 'TimeoutError')), 1);
        return controller.signal;
      },
    },
    createClient: () => client,
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (key) => ({ APPLE_PRIVATE_KEY: appleKey, SUPABASE_SERVICE_ROLE_KEY: 'service-key' })[key] ?? '' },
      serve: (callback) => { handler = callback; },
    },
  }));
  return {
    deletedUsers, appleCalls, timeouts,
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

test('an Apple account is deleted, then has its Apple token exchanged and revoked', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] } });
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
  assert.ok(f.appleCalls.every((c) => c.deletedYet), 'revocation must follow the deletion');
  assert.equal(f.timeouts.length, 2, 'both Apple calls must be bounded');

  const secret = await verifyClientSecret(exchange.form.client_secret);
  assert.ok(secret.valid, 'client secret must verify against the key');
  assert.deepEqual(secret.header, { alg: 'ES256', kid: 'Y8NRLTKXG3' });
  assert.equal(secret.payload.iss, 'R9TKT8U45R');
  assert.equal(secret.payload.sub, 'com.ghostcopy.ghostcopy');
  assert.equal(secret.payload.aud, 'https://appleid.apple.com');
  assert.ok(secret.payload.exp - secret.payload.iat <= 300);
});

test('a failed Apple revocation is reported but does not keep the data', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] }, revokeStatus: 400 });
  const response = await f.request({ apple_authorization_code: 'fresh-code' });
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.deepEqual(f.deletedUsers, ['user']);
});

test('an Apple account deleted without a code is still deleted, flagged unrevoked', async () => {
  const f = fixture({ user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] } });
  const response = await f.request();
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.equal(f.appleCalls.length, 0);
});

test('a failed delete says so', async () => {
  const f = fixture({ deleteError: new Error('db down') });
  assert.equal((await f.request()).status, 500);
});

test('a code for a different Apple ID revokes nothing, and the account is still deleted', async () => {
  // The device's Apple ID need not be the one on the GhostCopy account;
  // revoking it would leave the deleted account's authorization active.
  const f = fixture({
    user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] },
    codeSubject: 'someone-else',
  });
  const response = await f.request({ apple_authorization_code: 'fresh-code' });
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.deepEqual(f.appleCalls.map((c) => c.url), ['https://appleid.apple.com/auth/token']);
  assert.deepEqual(f.deletedUsers, ['user']);
});

test('a failed delete revokes nothing, so the account keeps its Apple authorization', async () => {
  const f = fixture({
    user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] },
    deleteError: new Error('db down'),
  });
  assert.equal((await f.request({ apple_authorization_code: 'fresh-code' })).status, 500);
  assert.equal(f.appleCalls.length, 0);
});

test('an Apple endpoint that never answers does not hold up the deletion', async () => {
  const f = fixture({
    user: { id: 'user', identities: [{ provider: 'apple', id: 'apple-sub', identity_data: { sub: 'apple-sub' } }] },
    appleHangs: true,
  });
  const response = await f.request({ apple_authorization_code: 'fresh-code' });
  assert.deepEqual(plain(response.body), { deleted: true, apple_revoked: false });
  assert.deepEqual(f.deletedUsers, ['user']);
});
