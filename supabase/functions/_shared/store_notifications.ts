// App store consent withdrawals, mapped onto the same revoke path a parent's
// withdrawal through the KWS portal takes (consent_service 'revoke').
//
// Apple: App Store Server Notifications V2 POSTs { signedPayload }. A
// RESCIND_CONSENT notification carries appData.signedAppTransactionInfo, whose
// appTransactionId is the one StoreKit's AppTransaction.appTransactionID gave
// the device at parent setup. Both JWS values are verified against Apple's root.
//
// Google Play has no server-to-server notification for revoked approvals. Play
// Console lists revoked installId values (Age signals > Revoked app approvals);
// an operator posts them to /google-revocations with a secret key.
// See docs/store-age-signals.md.

import { hmacHex, jsonResponse, row, type Row } from './crypto.ts';

export type Store = 'app_store' | 'google_play';

export interface StoreNotificationDependencies {
  verifyApple(jws: string): Promise<Row>;
  /** Revoke every parent-managed request bound to this store reference before
   * `signedAt` (ms). Returns the revoked request ids. */
  revoke(store: Store, refHash: string, signedAt: number): Promise<string[]>;
  /** Best-effort provider withdrawal, as for a portal withdrawal. */
  withdraw(requestId: string): Promise<void>;
  isMaintenance(request: Request): boolean;
  refPepper: string;
  bundleId: string;
  /** App Store environments accepted, e.g. ['Production'] or ['Production', 'Sandbox']. */
  environments: string[];
  /** The app's Apple ID, checked when the notification includes one (production only). */
  appAppleId?: number;
  now?: () => number;
}

const headers = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
function json(body: unknown, status = 200): Response {
  return jsonResponse(body, status, headers);
}

/** Store references are stored only as this keyed hash. Domain-separated from
 * parent-email hashes and device proofs made with the same key. */
export function storeRefHash(store: Store, id: string, pepper: string): Promise<string> {
  if (pepper.length < 32) return Promise.reject(new Error('Store reference key unavailable'));
  return hmacHex(`store-ref:${store}:${id}`, pepper);
}

/** Shapes accepted from clients and stores. Neither is documented as a format,
 * so these are bounds rather than exact patterns. */
export function validStoreRef(store: unknown, id: unknown): store is Store {
  if (typeof id !== 'string') return false;
  if (store === 'app_store') return /^[A-Za-z0-9-]{1,64}$/.test(id);
  if (store === 'google_play') return /^[A-Za-z0-9_-]{1,128}$/.test(id);
  return false;
}

class Rejected extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export function createStoreNotificationHandler(deps: StoreNotificationDependencies): (request: Request) => Promise<Response> {
  const now = deps.now ?? Date.now;

  async function revokeAll(store: Store, ids: string[], signedAt: number): Promise<number> {
    let revoked = 0;
    for (const id of ids) {
      const requests = await deps.revoke(store, await storeRefHash(store, id, deps.refPepper), signedAt);
      for (const requestId of requests) {
        revoked++;
        try { await deps.withdraw(requestId); } catch { /* Local denial persists. */ }
      }
    }
    return revoked;
  }

  async function apple(body: Row): Promise<Response> {
    if (typeof body.signedPayload !== 'string' || body.signedPayload.length > 16384) {
      throw new Rejected(400, 'signedPayload required.');
    }
    let payload: Row;
    try { payload = await deps.verifyApple(body.signedPayload); } catch {
      throw new Rejected(401, 'Invalid signature.');
    }
    // Every other type is acknowledged so the App Store stops retrying it.
    if (payload.notificationType !== 'RESCIND_CONSENT') return json({ received: true });
    const appData = row(payload.appData);
    const environment = String(appData.environment ?? '');
    if (appData.bundleId !== deps.bundleId || !deps.environments.includes(environment) ||
      (deps.appAppleId !== undefined && appData.appAppleId !== undefined && appData.appAppleId !== deps.appAppleId)) {
      return json({ received: true, ignored: true });
    }
    if (typeof appData.signedAppTransactionInfo !== 'string') throw new Rejected(400, 'App transaction required.');
    let transaction: Row;
    try { transaction = await deps.verifyApple(appData.signedAppTransactionInfo); } catch {
      throw new Rejected(401, 'Invalid signature.');
    }
    const signedAt = Number(payload.signedDate);
    if (transaction.bundleId !== deps.bundleId || String(transaction.receiptType ?? environment) !== environment ||
      !Number.isFinite(signedAt) || signedAt > now() + 300000) {
      throw new Rejected(400, 'Notification does not match this app.');
    }
    if (!validStoreRef('app_store', transaction.appTransactionId)) throw new Rejected(400, 'App transaction required.');
    const revoked = await revokeAll('app_store', [transaction.appTransactionId as string], signedAt);
    return json({ received: true, revoked });
  }

  async function google(request: Request, body: Row): Promise<Response> {
    if (!deps.isMaintenance(request)) throw new Rejected(403, 'Forbidden.');
    const ids = body.installIds;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 500 ||
      !ids.every((id) => validStoreRef('google_play', id))) {
      throw new Rejected(400, 'installIds must list 1-500 install IDs.');
    }
    // Play Console gives a revocation date per row; the operator posts the
    // export after the fact, so anything bound before now is revoked.
    const revoked = await revokeAll('google_play', [...new Set(ids as string[])], now());
    return json({ revoked });
  }

  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST') return json({ error: 'POST required.' }, 405);
    try {
      const text = await request.text();
      if (text.length > 65536) throw new Rejected(413, 'Request too large.');
      const body = row(JSON.parse(text));
      const path = new URL(request.url).pathname;
      if (path.endsWith('/apple')) return await apple(body);
      if (path.endsWith('/google-revocations')) return await google(request, body);
      throw new Rejected(404, 'Not found.');
    } catch (error) {
      if (error instanceof Rejected) return json({ error: error.message }, error.status);
      if (error instanceof SyntaxError) return json({ error: 'Invalid JSON.' }, 400);
      // A 5xx makes the App Store retry later. No payload or identifiers logged.
      return json({ error: 'Unavailable.' }, 503);
    }
  };
}
