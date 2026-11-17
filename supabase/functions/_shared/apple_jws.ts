// Verifies JWS values signed by the App Store: App Store Server Notifications
// V2 `signedPayload` and the `signedAppTransactionInfo` inside it.
//
// The x5c header carries leaf, intermediate and root. Only the leaf and
// intermediate are taken from the message. The intermediate must be signed by
// a pinned Apple root, never by the root the sender included. This follows
// Apple's JWSDecodedHeader documentation and the App Store Server Library:
// the intermediate carries the Apple Worldwide Developer Relations extension
// (1.2.840.113635.100.6.2.1) and the leaf carries the App Store receipt
// signing extension (1.2.840.113635.100.6.11.1).
//
// WebCrypto only: it runs in the Deno edge runtime and in the Node tests
// (test/backend/apple_jws_test.mjs).

import { sameBytes } from './crypto.ts';

/** Apple Root CA - G3, DER, from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer.
 * SHA-256 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179. */
export const appleRootCaG3 =
  'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==';

export const appleIntermediateOid = '1.2.840.113635.100.6.2.1';
export const appleLeafOid = '1.2.840.113635.100.6.11.1';

export class AppleJwsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AppleJwsError';
  }
}

type Bytes = Uint8Array<ArrayBuffer>;
interface Node { tag: number; start: number; body: number; end: number }
interface Certificate {
  raw: Bytes;
  tbs: Bytes;
  signatureAlgorithm: string;
  signature: Bytes;
  issuer: Bytes;
  subject: Bytes;
  notBefore: number;
  notAfter: number;
  spki: Bytes;
  curve: 'P-256' | 'P-384';
  extensions: Map<string, Bytes>;
}

const curves: Record<string, 'P-256' | 'P-384'> = {
  '1.2.840.10045.3.1.7': 'P-256',
  '1.3.132.0.34': 'P-384',
};
const signatureHashes: Record<string, 'SHA-256' | 'SHA-384'> = {
  '1.2.840.10045.4.3.2': 'SHA-256',
  '1.2.840.10045.4.3.3': 'SHA-384',
};

function fail(): never {
  throw new AppleJwsError('Invalid App Store signature.');
}

function node(bytes: Bytes, offset: number, limit = bytes.length): Node {
  if (offset + 2 > limit) fail();
  const tag = bytes[offset];
  let length = bytes[offset + 1];
  let body = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 3 || body + count > limit) fail();
    length = 0;
    for (let i = 0; i < count; i++) length = (length << 8) | bytes[body + i];
    body += count;
  }
  const end = body + length;
  if (end > limit) fail();
  return { tag, start: offset, body, end };
}

function children(bytes: Bytes, parent: Node): Node[] {
  const items: Node[] = [];
  for (let offset = parent.body; offset < parent.end;) {
    const child = node(bytes, offset, parent.end);
    items.push(child);
    offset = child.end;
  }
  return items;
}

function expect(item: Node | undefined, tag: number): Node {
  if (!item || item.tag !== tag) fail();
  return item;
}

function oid(bytes: Bytes, item: Node): string {
  expect(item, 0x06);
  const parts: number[] = [];
  let value = 0;
  for (let i = item.body; i < item.end; i++) {
    value = value * 128 + (bytes[i] & 0x7f);
    if (!(bytes[i] & 0x80)) {
      if (parts.length === 0) parts.push(value < 80 ? Math.floor(value / 40) : 2, value < 80 ? value % 40 : value - 80);
      else parts.push(value);
      value = 0;
    }
  }
  return parts.join('.');
}

function time(bytes: Bytes, item: Node): number {
  const text = new TextDecoder().decode(bytes.subarray(item.body, item.end));
  const match = item.tag === 0x17
    ? text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/)
    : item.tag === 0x18 ? text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/) : null;
  if (!match) fail();
  let year = Number(match[1]);
  if (item.tag === 0x17) year += year < 50 ? 2000 : 1900;
  return Date.UTC(year, Number(match[2]) - 1, Number(match[3]), Number(match[4]), Number(match[5]), Number(match[6]));
}

function parseCertificate(raw: Bytes): Certificate {
  const root = node(raw, 0);
  if (root.tag !== 0x30 || root.end !== raw.length) fail();
  const [tbsNode, algorithm, signatureBits] = children(raw, root);
  expect(tbsNode, 0x30);
  const fields = children(raw, tbsNode);
  let index = fields[0]?.tag === 0xa0 ? 1 : 0;
  expect(fields[index++], 0x02); // serial
  expect(fields[index++], 0x30); // signature algorithm, repeated below
  const issuer = expect(fields[index++], 0x30);
  const validity = children(raw, expect(fields[index++], 0x30));
  const subject = expect(fields[index++], 0x30);
  const spki = expect(fields[index++], 0x30);
  const extensions = new Map<string, Bytes>();
  for (; index < fields.length; index++) {
    if (fields[index].tag !== 0xa3) continue;
    const list = expect(children(raw, fields[index])[0], 0x30);
    for (const extension of children(raw, list)) {
      const parts = children(raw, expect(extension, 0x30));
      const value = expect(parts[parts.length - 1], 0x04);
      extensions.set(oid(raw, parts[0]), raw.subarray(value.body, value.end));
    }
  }
  const keyAlgorithm = children(raw, expect(children(raw, spki)[0], 0x30));
  if (oid(raw, keyAlgorithm[0]) !== '1.2.840.10045.2.1') fail();
  const curve = curves[oid(raw, keyAlgorithm[1])];
  if (!curve) fail();
  const bits = expect(signatureBits, 0x03);
  if (raw[bits.body] !== 0) fail();
  return {
    raw,
    tbs: raw.subarray(tbsNode.start, tbsNode.end),
    signatureAlgorithm: oid(raw, children(raw, expect(algorithm, 0x30))[0]),
    signature: raw.subarray(bits.body + 1, bits.end),
    issuer: raw.subarray(issuer.start, issuer.end),
    subject: raw.subarray(subject.start, subject.end),
    notBefore: time(raw, validity[0]),
    notAfter: time(raw, validity[1]),
    spki: raw.subarray(spki.start, spki.end),
    curve,
    extensions,
  };
}

/** DER ECDSA-Sig-Value to the fixed-width r||s form WebCrypto verifies. */
function rawSignature(der: Bytes, size: number): Bytes {
  const sequence = node(der, 0);
  if (sequence.tag !== 0x30 || sequence.end !== der.length) fail();
  const output = new Uint8Array(size * 2);
  children(der, sequence).forEach((integer, i) => {
    if (i > 1) fail();
    expect(integer, 0x02);
    let value = der.subarray(integer.body, integer.end);
    while (value.length > size && value[0] === 0) value = value.subarray(1);
    if (value.length > size) fail();
    output.set(value, i * size + size - value.length);
  });
  return output;
}

function isCertificateAuthority(certificate: Certificate): boolean {
  const value = certificate.extensions.get('2.5.29.19');
  if (!value) return false;
  const sequence = node(value, 0);
  const first = children(value, sequence)[0];
  return first?.tag === 0x01 && value[first.body] !== 0;
}

function publicKey(certificate: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey('spki', certificate.spki,
    { name: 'ECDSA', namedCurve: certificate.curve }, false, ['verify']);
}

async function signedBy(child: Certificate, issuer: Certificate): Promise<boolean> {
  const hash = signatureHashes[child.signatureAlgorithm];
  if (!hash || !sameBytes(child.issuer, issuer.subject)) return false;
  const size = issuer.curve === 'P-384' ? 48 : 32;
  return crypto.subtle.verify({ name: 'ECDSA', hash }, await publicKey(issuer),
    rawSignature(child.signature, size), child.tbs);
}

function base64(value: string): Bytes {
  const normal = value.replaceAll('-', '+').replaceAll('_', '/');
  const binary = atob(normal + '='.repeat((4 - normal.length % 4) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function decodeSegment(segment: string): Record<string, unknown> {
  const value: unknown = JSON.parse(new TextDecoder().decode(base64(segment)));
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
  return value as Record<string, unknown>;
}

export interface AppleJwsOptions {
  /** DER (or base64 DER) roots to trust. Production passes [appleRootCaG3]. */
  roots: (Uint8Array | string)[];
  /** Milliseconds; certificate validity is checked at this time. */
  now: number;
}

/** Verify an App Store JWS and return its decoded payload. Throws
 * AppleJwsError for anything that is not a valid App Store signature. */
export async function verifyAppleJws(jws: string, options: AppleJwsOptions): Promise<Record<string, unknown>> {
  try {
    const parts = jws.split('.');
    if (parts.length !== 3 || parts.some((part) => !/^[A-Za-z0-9_-]+$/.test(part))) fail();
    const header = decodeSegment(parts[0]);
    if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length < 2 ||
      !header.x5c.every((item) => typeof item === 'string')) fail();
    const [leaf, intermediate] = (header.x5c as string[]).slice(0, 2).map((item) => parseCertificate(base64(item)));
    const roots = options.roots.map((root) => parseCertificate(typeof root === 'string' ? base64(root) : new Uint8Array(root)));
    let anchored = false;
    for (const root of roots) {
      if (await signedBy(intermediate, root)) { anchored = true; break; }
    }
    if (!anchored || !await signedBy(leaf, intermediate)) fail();
    for (const certificate of [leaf, intermediate]) {
      if (options.now < certificate.notBefore || options.now > certificate.notAfter) fail();
    }
    if (!intermediate.extensions.has(appleIntermediateOid) || !isCertificateAuthority(intermediate) ||
      !leaf.extensions.has(appleLeafOid) || leaf.curve !== 'P-256') fail();
    const signature = base64(parts[2]);
    if (signature.length !== 64) fail();
    const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, await publicKey(leaf),
      signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
    if (!valid) fail();
    return decodeSegment(parts[1]);
  } catch (error) {
    if (error instanceof AppleJwsError) throw error;
    fail();
  }
}
