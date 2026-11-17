// Byte, hash and JSON helpers shared by the consent and store functions
// (consent_handler.ts, store_notifications.ts, apple_jws.ts).
//
// Nothing here reads Deno.env or other runtime state at import time, so the
// Node tests can load it alongside the modules that use it.

export type Row = Record<string, unknown>;

/** An object, or {} for anything else. */
export function row(value: unknown): Row {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Row : {};
}

/** A string, or '' for anything else. */
export function text(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

export function hex(value: ArrayBuffer | Uint8Array): string {
  return Array.from(value instanceof Uint8Array ? value : new Uint8Array(value),
    (n) => n.toString(16).padStart(2, '0')).join('');
}

export async function sha256Hex(value: string): Promise<string> {
  return hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
}

/** HMAC-SHA-256 of `value` under `key`, as lowercase hex. Callers check the
 * key length and apply their own domain prefix to `value`. */
export async function hmacHex(value: string, key: string): Promise<string> {
  const imported = await crypto.subtle.importKey('raw', new TextEncoder().encode(key),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', imported, new TextEncoder().encode(value)));
}

/** Constant-time comparison for equal-length inputs. */
export function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

export function sameText(a: string, b: string): boolean {
  return sameBytes(new TextEncoder().encode(a), new TextEncoder().encode(b));
}

export function jsonResponse(body: unknown, status: number, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers });
}
