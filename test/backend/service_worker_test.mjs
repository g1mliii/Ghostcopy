import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../website/sw.js', import.meta.url), 'utf8');
function fixture() {
  const stores = new Map();
  const handlers = new Map();
  let claimed = false;
  const caches = {
    async keys() { return [...stores.keys()]; },
    async delete(name) { return stores.delete(name); },
    async open(name) {
      if (!stores.has(name)) stores.set(name, new Map());
      const entries = stores.get(name);
      return {
        async addAll(paths) { for (const path of paths) entries.set(path, 'cached asset'); },
        async put(request, response) { entries.set(request.url, response); },
      };
    },
  };
  vm.runInNewContext(source, {
    URL, caches,
    self: {
      location: { origin: 'https://ghostcopy.app' },
      addEventListener: (name, handler) => handlers.set(name, handler),
      skipWaiting() {}, clients: { async claim() { claimed = true; } },
    },
  });
  return { stores, handlers, get claimed() { return claimed; } };
}

test('activation evicts parent credentials left by an older controlling worker', async () => {
  const f = fixture();
  const credentialUrl = 'https://ghostcopy.app/parents?token_hash=private-parent-token&type=magiclink';
  f.stores.set('ghostcopy-v5', new Map([[credentialUrl, 'parent page']]));
  let installed;
  f.handlers.get('install')({ waitUntil(promise) { installed = promise; } });
  await installed;
  let activated;
  f.handlers.get('activate')({ waitUntil(promise) { activated = promise; } });
  await activated;
  assert.equal(f.stores.has('ghostcopy-v5'), false);
  assert.ok(f.stores.size > 0, 'new offline assets remain available');
  assert.ok([...f.stores.values()].every((entries) => !entries.has(credentialUrl)));
  assert.equal(f.claimed, true);
});

test('parent confirmation navigations never enter the cache handler', () => {
  const f = fixture();
  for (const path of ['/parents', '/parents.html?token_hash=private&type=magiclink', '/parents?token_hash=private']) {
    let intercepted = false;
    f.handlers.get('fetch')({
      request: { method: 'GET', mode: 'navigate', url: `https://ghostcopy.app${path}` },
      respondWith() { intercepted = true; },
    });
    assert.equal(intercepted, false);
  }
  assert.equal(f.stores.size, 0);
});
