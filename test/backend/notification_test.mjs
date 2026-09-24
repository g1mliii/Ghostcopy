import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

// Execute the deployed handler with local Supabase/FCM doubles. Its runtime
// code is JavaScript; only the Deno-specific imports need replacing here.
const source = (await readFile(new URL('../../supabase/functions/send-clipboard-notification/index.ts', import.meta.url), 'utf8'))
  .replace(/^import .*;\r?\n/gm, '');

function fixture(count = 10, sendResult = null) {
  let handler;
  const messages = [];
  const updates = [];
  const client = {
    auth: { getUser: async () => ({ data: { user: { id: 'user' } }, error: null }) },
    from(table) {
      let updating = false;
      const result = () => ({
        data: table === 'user_rate_limit'
          ? { insert_count: count, window_start: new Date().toISOString() }
          : updating ? null : [{ id: 'phone', device_type: 'android', fcm_token: 'phone-token' }],
        error: null,
      });
      return {
        select() { return this; }, lt() { return this; }, eq() { return this; }, neq() { return this; }, in() { return this; },
        update(payload) { updating = true; updates.push({ table, payload }); return this; },
        async maybeSingle() { return result(); },
        then(resolve, reject) { return Promise.resolve(result()).then(resolve, reject); },
      };
    },
  };
  const context = vm.createContext({
    console, Date, Math,
    createClient: () => client,
    json: (body, status = 200) => ({ body, status }),
    corsPreflight: () => ({ status: 204 }),
    Deno: {
      env: { get: (name) => name === 'SUPABASE_SERVICE_ROLE_KEY' ? 'service-secret' : '' },
      serve: (callback) => { handler = callback; },
    },
    admin: {
      apps: [{}],
      messaging: () => ({
        async sendEach(batch) {
          messages.push(...batch);
          return sendResult ?? { successCount: batch.length, failureCount: 0 };
        },
      }),
    },
  });
  vm.runInContext(source, context);
  return {
    messages,
    updates,
    request: (token, id = 10, owner = 'user') => handler({
      method: 'POST', headers: new Headers({ Authorization: `Bearer ${token}` }),
      json: async () => ({ record: { id, user_id: owner, device_type: 'windows', content_type: 'text' } }),
    }),
  };
}

test('accepted tenth insert still sends its notification', async () => {
  const f = fixture();
  const response = await f.request('service-secret');
  assert.equal(response.status, 200);
  assert.equal(response.body.devices_notified, 1);
  assert.equal(f.messages[0].data.clipboard_id, '10');
});

test('earlier queued notification survives a subsequently full insert window', async () => {
  const f = fixture();
  const response = await f.request('service-secret', 1);
  assert.equal(response.status, 200);
  assert.equal(f.messages[0].data.clipboard_id, '1');
});

test('ordinary authenticated callers do not bypass throttling', async () => {
  const f = fixture();
  assert.equal((await f.request('user-token')).status, 429);
  assert.equal(f.messages.length, 0);
});

test('ordinary callers still cannot name another account', async () => {
  const f = fixture(1);
  assert.equal((await f.request('user-token', 1, 'other-user')).status, 403);
  assert.equal(f.messages.length, 0);
});

test('a failed send reports FCM\'s reason, never the token', async () => {
  // An iPhone stopped receiving and the response said only devices_failed: 1.
  // The code is what tells an APNs credential problem from a dead token.
  const f = fixture(10, {
    successCount: 0,
    failureCount: 1,
    responses: [{
      success: false,
      error: { code: 'messaging/third-party-auth-error', message: 'Auth error from APNS or Web Push Service' },
    }],
  });
  const response = await f.request('service-secret');
  assert.equal(response.status, 200);
  assert.equal(response.body.devices_failed, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(response.body.failures)), [{
    device_type: 'android',
    device_name: null,
    code: 'messaging/third-party-auth-error',
    message: 'Auth error from APNS or Web Push Service',
  }]);
  assert.ok(!JSON.stringify(response.body).includes('phone-token'));
});

const clearedTokens = (f) => f.updates.filter(
  (u) => u.table === 'devices' && 'fcm_token' in u.payload && u.payload.fcm_token === null,
);

test('an APNs token Apple rejects is cleared, not retried forever', async () => {
  const f = fixture(10, {
    successCount: 0,
    failureCount: 1,
    responses: [{
      success: false,
      error: { code: 'messaging/invalid-argument', message: 'APNs device token is invalid.' },
    }],
  });
  await f.request('service-secret');
  assert.equal(clearedTokens(f).length, 1);
});

test('an invalid-argument for any other reason keeps the token', async () => {
  const f = fixture(10, {
    successCount: 0,
    failureCount: 1,
    responses: [{
      success: false,
      error: { code: 'messaging/invalid-argument', message: 'Invalid value at message.data' },
    }],
  });
  await f.request('service-secret');
  assert.equal(clearedTokens(f).length, 0);
});
