import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { sharedKeysSource, cloudAccessSource } from './shared_keys.mjs';

const source = sharedKeysSource + cloudAccessSource + stripTypeScriptTypes(
  (await readFile(new URL('../../supabase/functions/exchange-link-token/index.ts', import.meta.url), 'utf8'))
    .replace(/^import .*\r?\n/gm, ''),
);

async function fixture({ expireDuringCheck = false } = {}) {
  let now = Date.now();
  class ClockDate extends Date {
    constructor(value) { super(value === undefined ? now : value); }
    static now() { return now; }
  }
  const token = 'a'.repeat(64);
  const pin = '123456';
  const pinHash = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(pin))).toString('hex');
  let row = { user_id: 'child', token, pin_hash: pinHash, expires_at: new Date(now + 60000).toISOString() };
  let allowed = false;
  let handler;
  let restores = 0;
  let sessionRequests = 0;
  const client = {
    from(table) {
      assert.equal(table, 'mobile_link_tokens');
      const conditions = {};
      return {
        delete() { return this; },
        eq(key, value) { conditions[key] = value; return this; },
        gt(key, value) { conditions[key] = value; return this; },
        select() { return this; },
        async maybeSingle() {
          if (!row || conditions.token !== row.token || conditions.pin_hash !== row.pin_hash || row.expires_at <= conditions.expires_at) {
            return { data: null, error: null };
          }
          const consumed = { user_id: row.user_id, expires_at: row.expires_at };
          row = null;
          return { data: consumed, error: null };
        },
        async insert(restored) { restores++; row = restored; return { error: null }; },
      };
    },
    rpc(name) {
      if (name === 'register_link_token_pin_failure') return { async maybeSingle() { return { data: null, error: null }; } };
      assert.equal(name, 'consent_service');
      if (expireDuringCheck) now += 120000;
      return Promise.resolve({ data: { allowed, fileSync: true, parentManaged: true }, error: null });
    },
    auth: {
      admin: {
        async getUserById() { return { data: { user: { id: 'child', email: 'child@anon.ghostcopy.app' } }, error: null }; },
        async generateLink() { sessionRequests++; return { data: { properties: { hashed_token: 'hashed' } }, error: null }; },
      },
      async verifyOtp() {
        return { data: { session: { access_token: 'access', refresh_token: 'refresh' }, user: { id: 'child', is_anonymous: false } }, error: null };
      },
    },
  };
  vm.runInNewContext(source, {
    crypto, TextEncoder, Date: ClockDate, console,
    createClient: () => client,
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (name) => ({ SUPABASE_URL: 'https://api.example', SUPABASE_SERVICE_ROLE_KEY: 'secret', SUPABASE_ANON_KEY: 'public' })[name] },
      serve: (callback) => { handler = callback; },
    },
  });
  return {
    get restores() { return restores; },
    get sessionRequests() { return sessionRequests; },
    get live() { return row !== null; },
    allow() { allowed = true; },
    request: () => handler({ method: 'POST', json: async () => ({ token, pin }) }),
  };
}

test('a denied QR exchange restores the live token and permits retry after authorization', async () => {
  const f = await fixture();
  assert.equal((await f.request()).status, 403);
  assert.equal(f.restores, 1);
  assert.equal(f.live, true);
  assert.equal(f.sessionRequests, 0, 'denial cannot mint a session');
  f.allow();
  const retry = await f.request();
  assert.equal(retry.status, 200);
  assert.equal(retry.body.refresh_token, 'refresh');
  assert.equal(f.live, false);
  assert.equal(f.sessionRequests, 1);
  assert.equal((await f.request()).status, 400, 'successful exchange stays single-use');
});

test('authorization denial cannot resurrect a link that expired during the check', async () => {
  const f = await fixture({ expireDuringCheck: true });
  assert.equal((await f.request()).status, 403);
  assert.equal(f.restores, 0);
  assert.equal(f.live, false);
  assert.equal(f.sessionRequests, 0);
});
