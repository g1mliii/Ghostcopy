import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const source = stripTypeScriptTypes((await readFile(new URL('../../supabase/functions/storage-presign/index.ts', import.meta.url), 'utf8'))
  .replace(/^import .*;\r?\n/gm, ''));
class Command { constructor(input) { this.input = input; } }
function fixture({ shared = { count: 0 }, rows = [], failRate = false, failedKeys = [], failDelete = false } = {}) {
  let handler;
  const acknowledged = [];
  const deleted = [];
  let signed = 0;
  const client = {
    auth: { getUser: async () => ({ data: { user: { id: 'user' } }, error: null }) },
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
    console, Date, Math, Set, Map,
    createClient: () => client,
    DeleteObjectCommand: Command, DeleteObjectsCommand: Command,
    GetObjectCommand: Command, PutObjectCommand: Command,
    S3Client: class {
      async send(command) {
        if (failDelete) throw new Error('R2 unavailable');
        const keys = command.input.Delete.Objects.map((o) => o.Key);
        deleted.push(...keys);
        return {
          Deleted: keys.filter((key) => !failedKeys.includes(key)).map((Key) => ({ Key })),
          Errors: failedKeys.map((Key) => ({ Key, Code: 'InternalError' })),
        };
      }
    },
    getSignedUrl: async () => { signed++; return 'https://example.com/signed'; },
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (key) => key === 'SUPABASE_SERVICE_ROLE_KEY' ? 'service-key' : '' },
      serve: (callback) => { handler = callback; },
    },
  }));
  return {
    acknowledged, deleted, get signed() { return signed; },
    request: (body, token = 'user-token') => handler({
      method: 'POST', headers: new Headers({ Authorization: `Bearer ${token}` }), json: async () => body,
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
  assert.deepEqual(f.deleted, ['a/one', 'b/two']);
});

test('a network failure leaves every leased deletion retryable', async () => {
  const f = fixture({ rows: [{ id: 1, owner_id: 'a', storage_path: 'a/one' }], failDelete: true });
  assert.equal((await f.request({ action: 'delete_queued' }, 'service-key')).status, 500);
  assert.equal(f.acknowledged.length, 0);
});

test('a queued owner mismatch cannot delete an unrelated object', async () => {
  const f = fixture({ rows: [{ id: 1, owner_id: 'a', storage_path: 'b/one' }] });
  assert.equal((await f.request({ action: 'delete_queued' }, 'service-key')).status, 500);
  assert.equal(f.deleted.length, 0);
});
