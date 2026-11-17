import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { test } from 'node:test';
import { importShared } from './ts_module.mjs';

const { hex, hmacHex, row, sameBytes, sameText, sha256Hex, text } = await importShared('crypto.ts');
const { storeRefHash } = await importShared('store_notifications.ts');
const pepper = 'a-private-test-only-pepper-at-least-32-characters';

test('hashes match Node crypto byte for byte', async () => {
  assert.equal(await sha256Hex('claim'), createHash('sha256').update('claim').digest('hex'));
  assert.equal(await hmacHex('parent@example.test', pepper),
    createHmac('sha256', pepper).update('parent@example.test').digest('hex'));
  assert.equal(hex(new Uint8Array([0, 15, 255])), '000fff');
  assert.equal(hex(new Uint8Array([1, 2]).buffer), '0102');
});

test('store reference hashes keep their domain prefix', async () => {
  assert.equal(await storeRefHash('app_store', '704289572311430368', pepper),
    createHmac('sha256', pepper).update('store-ref:app_store:704289572311430368').digest('hex'));
  assert.notEqual(await storeRefHash('google_play', '704289572311430368', pepper),
    await storeRefHash('app_store', '704289572311430368', pepper));
  await assert.rejects(storeRefHash('app_store', '1', 'short'));
});

test('comparisons and shape helpers', () => {
  assert.equal(sameText('abc', 'abc'), true);
  assert.equal(sameText('abc', 'abd'), false);
  assert.equal(sameText('abc', 'ab'), false);
  assert.equal(sameBytes(new Uint8Array([1]), new Uint8Array([1])), true);
  assert.deepEqual(row([1]), {});
  assert.deepEqual(row(null), {});
  assert.deepEqual(row({ a: 1 }), { a: 1 });
  assert.equal(text(1), '');
  assert.equal(text('x'), 'x');
});
