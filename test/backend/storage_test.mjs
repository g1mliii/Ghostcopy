import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { sharedKeysSource } from './shared_keys.mjs';

const source = sharedKeysSource + stripTypeScriptTypes((await readFile(new URL('../../supabase/functions/storage-presign/index.ts', import.meta.url), 'utf8'))
  .replace(/^import .*;\r?\n/gm, ''));
class Command { constructor(input) { this.input = input; } }
function fixture({ shared = { count: 0 }, rows = [], failRate = false, failedKeys = [], missingKeys = [], failDelete = false,
  env = { SUPABASE_SERVICE_ROLE_KEY: 'service-key' } } = {}) {
  let userChecks = 0;
  let handler;
  const acknowledged = [];
  const deleted = [];
  let signed = 0;
  const client = {
    auth: { getUser: async () => { userChecks++; return { data: { user: { id: 'user' } }, error: null }; } },
    async rpc(name, args) {
      if (name === 'check_storage_rate_limit') {
        assert.equal(args.p_user_id, 'user');
        return failRate ? { error: new Error('offline') } :
          { data: [{ allowed: ++shared.count <= 20, retry_after_seconds: 60 }] };
      }
      if (name === 'claim_storage_cleanup_batch') return { data: rows };
      if (name === 'acknowledge_storage_cleanup') {
        acknowledged.push(...args.p_ids); return { error: null };
      }
      throw new Error(`Unexpected RPC ${name}`);
    },
  };
  vm.runInContext(source, vm.createContext({
    console, Date, Math, Set, Map, TextEncoder,
    createClient: () => client,
    DeleteObjectCommand: Command, DeleteObjectsCommand: Command,
    GetObjectCommand: Command, PutObjectCommand: Command,
    S3Client: class {
      async send() { throw new Error('The function must not call R2 through the SDK - it hung in the Edge runtime'); }
    },
    AbortSignal,
    // Deletes are presigned and sent with fetch; the URL carries the key.
    getSignedUrl: async (_client, command) => { signed++; return `https://r2.example/${command.input.Key}`; },
    fetch: async (url, init) => {
      assert.equal(init.method, 'DELETE');
      if (failDelete) throw new Error('R2 unavailable');
      const key = url.slice('https://r2.example/'.length);
      deleted.push(key);
      if (missingKeys.includes(key)) return { ok: false, status: 404 };
      return failedKeys.includes(key) ? { ok: false, status: 500 } : { ok: true, status: 204 };
    },
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (key) => env[key] ?? '' },
      serve: (callback) => { handler = callback; },
    },
  }));
  return {
    acknowledged, deleted, get signed() { return signed; }, get userChecks() { return userChecks; },
    // A session token is a JWT; the function refuses anything not shaped like
    // one before asking auth.
    request: (body, token = 'user.session.token', { parsed } = {}) => handler({
      method: 'POST', headers: new Headers({ Authorization: `Bearer ${token}` }),
      json: async () => { if (parsed) parsed.read = true; return body; },
    }),
  };
}

test('a fresh edge instance uses the same storage rate budget', async () => {
  const shared = { count: 0 };
  const first = fixture({ shared });
  const upload = { action: 'upload', path: 'user/file', size: 10 };
  for (let i=0; i<20; i++) assert.equal((await first.request(upload)).status, 200);
  const second = fixture({ shared });
  assert.equal((await second.request(upload)).status, 429);
  assert.equal(second.signed, 0);
});

test('an unavailable rate-limit store fails closed', async () => {
  const f = fixture({ failRate: true });
  assert.equal((await f.request({ action: 'download', path: 'user/file' })).status, 500);
  assert.equal(f.signed, 0);
});

test('ordinary users cannot drain the privileged cleanup queue', async () => {
  const f = fixture();
  assert.equal((await f.request({ action: 'delete_queued' })).status, 403);
  assert.equal(f.deleted.length, 0);
});

test('a partial R2 batch acknowledges only successful objects', async () => {
  const f = fixture({
    rows: [{ id: 1, owner_id: 'a', storage_path: 'a/one' }, { id: 2, owner_id: 'b', storage_path: 'b/two' }],
    failedKeys: ['b/two'],
  });
  const response = await f.request({ action: 'delete_queued' }, 'service-key');
  assert.equal(response.status, 502);
  assert.deepEqual(f.acknowledged, [1]);
  assert.deepEqual([...f.deleted].sort(), ['a/one', 'b/two']);
});

test('a network failure leaves every leased deletion retryable', async () => {
  const f = fixture({ rows: [{ id: 1, owner_id: 'a', storage_path: 'a/one' }], failDelete: true });
  assert.equal((await f.request({ action: 'delete_queued' }, 'service-key')).status, 502);
  assert.equal(f.acknowledged.length, 0);
});

test('a queued owner mismatch cannot delete an unrelated object', async () => {
  const f = fixture({ rows: [{ id: 1, owner_id: 'a', storage_path: 'b/one' }] });
  assert.equal((await f.request({ action: 'delete_queued' }, 'service-key')).status, 500);
  assert.equal(f.deleted.length, 0);
});

test('a full batch is deleted and acknowledged', async () => {
  const rows = Array.from({ length: 12 }, (_, i) => ({ id: i + 1, owner_id: 'a', storage_path: `a/file-${i}` }));
  const f = fixture({ rows });
  const response = await f.request({ action: 'delete_queued' }, 'service-key');
  assert.equal(response.status, 200);
  assert.deepEqual([...f.acknowledged].sort((x, y) => x - y), rows.map((r) => r.id));
  assert.equal(f.deleted.length, 12);
});

test('a 404 is left queued, since a missing key would answer 204', async () => {
  // DeleteObject is idempotent: an absent key gets 204. A 404 is the bucket
  // or endpoint, and acknowledging it would orphan the file for good.
  const f = fixture({ rows: [{ id: 1, owner_id: 'a', storage_path: 'a/file' }], missingKeys: ['a/file'] });
  assert.equal((await f.request({ action: 'delete_queued' }, 'service-key')).status, 502);
  assert.deepEqual(f.acknowledged, []);
});

test('an anonymous request is refused before its body or an auth check', async () => {
  // The platform's JWT gate is off for this function, so this is the gate.
  const f = fixture();
  const parsed = { read: false };
  assert.equal((await f.request({ action: 'download', path: 'user/file' }, 'not-a-jwt', { parsed })).status, 401);
  assert.equal(parsed.read, false);
  assert.equal(f.userChecks, 0);
});

test('the cleanup trigger is accepted on a current secret key', async () => {
  // Production: the new variables, with the legacy one injected too.
  const f = fixture({
    rows: [{ id: 1, owner_id: 'user', storage_path: 'user/a' }],
    env: {
      SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_a' }),
      SUPABASE_SERVICE_ROLE_KEY: 'legacy.service.jwt',
    },
  });
  assert.equal((await f.request({ action: 'delete_queued' }, 'sb_secret_a')).status, 200);
  assert.deepEqual(f.acknowledged, [1]);
});

test('a disabled legacy JWT cannot drain the cleanup queue', async () => {
  const f = fixture({
    rows: [{ id: 1, owner_id: 'user', storage_path: 'user/a' }],
    env: {
      SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_a' }),
      SUPABASE_SERVICE_ROLE_KEY: 'legacy.service.jwt',
    },
  });
  // Shaped like a session, so it reaches the user check - and a user is not
  // the trigger.
  assert.equal((await f.request({ action: 'delete_queued' }, 'legacy.service.jwt')).status, 403);
  assert.equal(f.deleted.length, 0);
});
