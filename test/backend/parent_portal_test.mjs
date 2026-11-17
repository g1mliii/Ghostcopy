import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { setImmediate } from 'node:timers/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../website/parents.js', import.meta.url), 'utf8');

function fixture({ logoutStatus = 204, logoutBody = null } = {}) {
  const nodes = new Map();
  const requests = [];
  function node(id) {
    if (!nodes.has(id)) nodes.set(id, {
      textContent: '', hidden: false, disabled: false, value: '',
      handlers: new Map(),
      addEventListener(name, callback) { this.handlers.set(name, callback); },
      replaceChildren() {}, reportValidity() { return true; },
    });
    return nodes.get(id);
  }
  vm.runInNewContext(source, {
    URL, URLSearchParams, AbortSignal,
    location: { search: '', pathname: '/parents' },
    history: { replaceState() {} },
    document: {
      getElementById: node,
      querySelectorAll: () => [node('signout'), node('create')],
    },
    async fetch(url, options) {
      requests.push({ url, ...options });
      if (url.endsWith('/auth/v1/token?grant_type=password')) {
        return Response.json({ access_token: 'parent-session' });
      }
      if (url.endsWith('/auth/v1/logout')) {
        assert.equal(options.headers.Authorization, 'Bearer parent-session');
        return new Response(logoutBody, { status: logoutStatus });
      }
      assert.ok(url.endsWith('/functions/v1/cloud-consent'));
      const body = JSON.parse(options.body);
      if (body.action === 'parent-list') return Response.json({ children: [] });
      assert.equal(body.action, 'configuration');
      return Response.json({ parentPortalUrl: null });
    },
  });
  return {
    node, requests,
    async fire(id, name) {
      await node(id).handlers.get(name)({ preventDefault() {} });
      for (let attempt = 0; attempt < 50 && node('signout').disabled; attempt++) await setImmediate();
      assert.equal(node('signout').disabled, false, 'request must finish');
    },
  };
}

for (const [status, body] of [[204, null], [200, ''], [200, '  ']]) {
  test(`successful logout with status ${status} and an empty body keeps the signed-out message`, async () => {
    const f = fixture({ logoutStatus: status, logoutBody: body });
    f.node('email').value = 'parent@example.test';
    f.node('password').value = 'test-password';
    await f.fire('login-form', 'submit');
    assert.equal(f.node('status').textContent, 'Signed in.');
    await f.fire('signout', 'click');
    assert.equal(f.node('status').textContent, 'Signed out.');
    assert.equal(f.node('accounts').hidden, true);
    assert.equal(f.node('login').hidden, false);
    assert.equal(f.requests.filter((request) => request.url.endsWith('/auth/v1/logout')).length, 1);
  });
}

test('a failed empty logout response still reports failure and clears local access', async () => {
  const f = fixture({ logoutStatus: 503, logoutBody: '' });
  f.node('email').value = 'parent@example.test';
  f.node('password').value = 'test-password';
  await f.fire('login-form', 'submit');
  await f.fire('signout', 'click');
  assert.match(f.node('status').textContent, /Could not complete the request/);
  assert.equal(f.node('accounts').hidden, true);
  assert.equal(f.node('login').hidden, false);
});
