// A test-only App Store style certificate chain and JWS signer. The shapes
// follow Apple's JWSDecodedHeader documentation: a P-256 leaf carrying
// 1.2.840.113635.100.6.11.1, an intermediate CA carrying
// 1.2.840.113635.100.6.2.1, and a P-384 root.
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const source = await readFile(new URL('../../supabase/functions/_shared/apple_jws.ts', import.meta.url), 'utf8');
export const appleJws = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source, { mode: 'transform' })).toString('base64')}`);

const length = (n) => n < 128 ? [n] : n < 256 ? [0x81, n] : [0x82, n >> 8, n & 255];
const tlv = (tag, ...parts) => {
  const body = Buffer.concat(parts.map((part) => Buffer.from(part)));
  return Buffer.concat([Buffer.from([tag, ...length(body.length)]), body]);
};
const seq = (...parts) => tlv(0x30, ...parts);
function oid(text) {
  const [a, b, ...rest] = text.split('.').map(Number);
  const out = [40 * a + b];
  for (const n of rest) {
    const bytes = [n & 0x7f];
    for (let v = Math.floor(n / 128); v; v = Math.floor(v / 128)) bytes.unshift((v & 0x7f) | 0x80);
    out.push(...bytes);
  }
  return tlv(0x06, Buffer.from(out));
}
const utc = (ms) => tlv(0x17, Buffer.from(new Date(ms).toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'));
const name = (cn) => seq(tlv(0x31, seq(oid('2.5.4.3'), tlv(0x0c, Buffer.from(cn)))));
const extension = (id, value) => seq(oid(id), tlv(0x04, value));
const caFlag = seq(tlv(0x01, [0xff]));
const marker = tlv(0x05);
function derSignature(raw) {
  const half = raw.length / 2;
  const integer = (bytes) => {
    let value = Buffer.from(bytes);
    while (value.length > 1 && value[0] === 0 && !(value[1] & 0x80)) value = value.subarray(1);
    if (value[0] & 0x80) value = Buffer.concat([Buffer.from([0]), value]);
    return tlv(0x02, value);
  };
  return seq(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
}

export async function keyPair(curve) {
  return crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: curve }, true, ['sign', 'verify']);
}

/** Issue a certificate for `subjectKey`, signed by `issuerKey` (P-384 issuers sign with SHA-384). */
export async function certificate({ subject, issuer, subjectKey, issuerKey, issuerCurve = 'P-384',
  extensions = [], notBefore = Date.now() - 86400000, notAfter = Date.now() + 86400000 * 365 }) {
  const hash = issuerCurve === 'P-384' ? 'SHA-384' : 'SHA-256';
  const algorithm = seq(oid(hash === 'SHA-384' ? '1.2.840.10045.4.3.3' : '1.2.840.10045.4.3.2'));
  const spki = Buffer.from(await crypto.subtle.exportKey('spki', subjectKey.publicKey));
  const tbs = seq(tlv(0xa0, tlv(0x02, [2])), tlv(0x02, [1]), algorithm, name(issuer),
    seq(utc(notBefore), utc(notAfter)), name(subject), spki,
    ...(extensions.length ? [tlv(0xa3, seq(...extensions))] : []));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash }, issuerKey.privateKey, tbs));
  return seq(tbs, algorithm, tlv(0x03, Buffer.from([0]), derSignature(signature)));
}

/** Root, intermediate and leaf, shaped like the App Store's signing chain. */
export async function appleChain(overrides = {}) {
  const rootKey = await keyPair('P-384');
  const intermediateKey = await keyPair('P-384');
  const leafKey = await keyPair('P-256');
  const root = await certificate({ subject: 'Test Root', issuer: 'Test Root', subjectKey: rootKey,
    issuerKey: rootKey, extensions: [extension('2.5.29.19', caFlag)] });
  const intermediate = await certificate({ subject: 'Test WWDR', issuer: 'Test Root', subjectKey: intermediateKey,
    issuerKey: rootKey, extensions: overrides.intermediateExtensions ??
      [extension('2.5.29.19', caFlag), extension(appleJws.appleIntermediateOid, marker)] });
  const leaf = await certificate({ subject: 'Test Store Signing', issuer: 'Test WWDR', subjectKey: leafKey,
    issuerKey: intermediateKey, extensions: overrides.leafExtensions ?? [extension(appleJws.appleLeafOid, marker)],
    ...(overrides.leafValidity ?? {}) });
  return { root, intermediate, leaf, rootKey, intermediateKey, leafKey };
}
export { extension, marker };

const b64url = (value) => Buffer.from(value).toString('base64url');

/** Sign `payload` as the App Store does: ES256 with the chain in x5c. */
export async function signJws(payload, chain, { alg = 'ES256', key = chain.leafKey } = {}) {
  const header = b64url(JSON.stringify({ alg, x5c: [chain.leaf, chain.intermediate, chain.root].map((c) => c.toString('base64')) }));
  const body = b64url(JSON.stringify(payload));
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, new TextEncoder().encode(`${header}.${body}`));
  return `${header}.${body}.${b64url(new Uint8Array(signature))}`;
}
