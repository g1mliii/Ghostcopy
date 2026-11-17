import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { appleChain, appleJws, certificate, extension, keyPair, marker, signJws } from './apple_fixture.mjs';

const { verifyAppleJws, appleRootCaG3, appleLeafOid, appleIntermediateOid } = appleJws;
const payload = { notificationType: 'RESCIND_CONSENT', signedDate: Date.now() };
const verify = (jws, root, now = Date.now()) => verifyAppleJws(jws, { roots: [root], now });

test('the pinned root is Apple Root CA - G3', () => {
  const fingerprint = createHash('sha256').update(Buffer.from(appleRootCaG3, 'base64')).digest('hex').toUpperCase();
  assert.equal(fingerprint, '63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179');
});

test('a JWS chained to a pinned root returns its payload', async () => {
  const chain = await appleChain();
  assert.deepEqual(await verify(await signJws(payload, chain), chain.root), payload);
});

test('the root inside x5c is never trusted', async () => {
  const chain = await appleChain();
  const pinned = await appleChain();
  // A self-made chain is internally valid but does not reach the pinned root.
  await assert.rejects(verify(await signJws(payload, chain), pinned.root), /Invalid App Store signature/);
  await assert.rejects(verifyAppleJws(await signJws(payload, chain), { roots: [appleRootCaG3], now: Date.now() }));
});

test('a changed payload or a signature from another key fails', async () => {
  const chain = await appleChain();
  const [header, , signature] = (await signJws(payload, chain)).split('.');
  const forged = Buffer.from(JSON.stringify({ ...payload, notificationType: 'TEST' })).toString('base64url');
  await assert.rejects(verify(`${header}.${forged}.${signature}`, chain.root));
  await assert.rejects(verify(await signJws(payload, chain, { key: await keyPair('P-256') }), chain.root));
});

test('only ES256 is accepted', async () => {
  const chain = await appleChain();
  for (const alg of ['none', 'HS256', 'ES384']) {
    await assert.rejects(verify(await signJws(payload, chain, { alg }), chain.root));
  }
});

test('the Apple certificate extensions are required on leaf and intermediate', async () => {
  const noLeafOid = await appleChain({ leafExtensions: [extension('1.2.3.4', marker)] });
  await assert.rejects(verify(await signJws(payload, noLeafOid), noLeafOid.root));
  const noIntermediateOid = await appleChain({ intermediateExtensions: [extension('2.5.29.19', Buffer.from([0x30, 3, 1, 1, 0xff]))] });
  await assert.rejects(verify(await signJws(payload, noIntermediateOid), noIntermediateOid.root));
  const notCa = await appleChain({ intermediateExtensions: [extension(appleIntermediateOid, marker)] });
  await assert.rejects(verify(await signJws(payload, notCa), notCa.root));
  assert.equal(appleLeafOid, '1.2.840.113635.100.6.11.1');
});

test('an expired or not-yet-valid leaf fails', async () => {
  const expired = await appleChain({ leafValidity: { notBefore: Date.now() - 2 * 86400000, notAfter: Date.now() - 86400000 } });
  await assert.rejects(verify(await signJws(payload, expired), expired.root));
  const chain = await appleChain();
  await assert.rejects(verify(await signJws(payload, chain), chain.root, Date.now() - 7 * 86400000));
});

test('a leaf signed by a key that only names the intermediate fails', async () => {
  const chain = await appleChain();
  const impostor = await keyPair('P-384');
  const leaf = await certificate({ subject: 'Test Store Signing', issuer: 'Test WWDR', subjectKey: chain.leafKey,
    issuerKey: impostor, extensions: [extension(appleLeafOid, marker)] });
  await assert.rejects(verify(await signJws(payload, { ...chain, leaf }), chain.root));
});

test('malformed input fails closed with the same error', async () => {
  const chain = await appleChain();
  for (const value of ['', 'a.b', 'a.b.c', '***.***.***', `${Buffer.from('{"alg":"ES256","x5c":["AAAA","AAAA"]}').toString('base64url')}.e30.AAAA`]) {
    await assert.rejects(verify(value, chain.root), /Invalid App Store signature/);
  }
});
