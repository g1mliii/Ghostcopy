import { hex, hmacHex, jsonResponse, row, type Row, sameText, sha256Hex as hash, text } from './crypto.ts';
import { KwsClient, parentalNoticeVersion, verifyKwsSignature } from './kws.ts';
import { storeRefHash, validStoreRef } from './store_notifications.ts';

export interface ConsentDependencies {
  operation(action: string, data?: Row): Promise<unknown>;
  /** public.store_consent_service: binds an app store reference to a request
   * so the store's consent withdrawal can revoke it. */
  storeOperation(action: string, data: Row): Promise<unknown>;
  authenticate(request: Request): Promise<{ id: string; email?: string; emailConfirmed: boolean } | null>;
  isMaintenance(request: Request): boolean;
  deleteUser(id: string): Promise<void>;
  exportUser(id: string, offset: number): Promise<unknown>;
  exportFile(id: string, path: string): Promise<unknown>;
  kws: Pick<KwsClient, 'requestConsent' | 'permissions' | 'withdraw' | 'deleteSubject'> | null;
  organizationId: string;
  productId: string;
  parentPepper: string;
  parentPortalUrl: string;
  webhookSecrets: Record<string, string[]>;
  now?: () => number;
}

class Rejected extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const headers = {
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json', 'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};
function json(body: unknown, status = 200): Response {
  return jsonResponse(body, status, headers);
}
function parentHash(email: string, pepper: string): Promise<string> {
  return hmac(email.trim().toLowerCase(), pepper);
}
function hmac(value: string, pepper: string): Promise<string> {
  if (pepper.length < 32) throw new Rejected(503, 'Parent setup is unavailable.');
  return hmacHex(value, pepper);
}
async function deviceProof(request: Row, pepper: string, now: number): Promise<string> {
  const payload = btoa(JSON.stringify({ id: request.id, userId: request.bound_user_id,
    expiresAt: now + 366 * 86400000 })).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  return `device.v1.${payload}.${await hmac(`device-proof:${payload}`, pepper)}`;
}
function publicRequest(request: Row, now: number): Row {
  const adulthood = new Date(text(request.created_at));
  adulthood.setUTCFullYear(adulthood.getUTCFullYear() + 18 - Number(request.age));
  const expired = !request.bound_user_id && Date.parse(text(request.expires_at)) <= now;
  const authorized = !expired && request.status === 'authorized' && request.cloud_sync === true &&
    request.requires_new_consent === false && Date.parse(text(request.valid_until)) > now;
  return { independentEligible: Number.isFinite(adulthood.getTime()) && adulthood.getTime() <= now,
    status: expired ? 'expired' : authorized ? 'authorized' :
    // A stored 'authorized' with a lapsed lease is not a current permission.
    request.requires_new_consent ? 'revoked' :
    request.status === 'initiating' || request.status === 'authorized' ? 'pending' : request.status,
  hasAccount: !!request.bound_user_id, cloudSync: authorized, fileSync: authorized && request.file_sync === true,
  expiresAt: request.expires_at, validUntil: request.valid_until,
  accountLabel: `GhostCopy account ${text(request.id).slice(-6)}` };
}

/** Dependency-injected HTTP boundary; tests exercise the same handler as production. */
export function createConsentHandler(deps: ConsentDependencies): (request: Request) => Promise<Response> {
  const now = deps.now ?? Date.now;
  const configured = () => deps.kws !== null && deps.parentPepper.length >= 32 &&
    /^https:\/\/[a-z0-9.-]+\.kidswebservices\.com(?:\/[^?#]*)?$/.test(deps.parentPortalUrl) &&
    ['consent:changed', 'consent:deleted', 'settings:effective-values-changed',
      'settings:parent-limits-changed', 'families:user-removed-from-family',
      'families:family-group-deleted'].every((name) => deps.webhookSecrets[name]?.length);

  async function refresh(request: Row, force = false): Promise<Row> {
    if (!deps.kws || !request.id) return request;
    const lease = row(await deps.operation('begin_refresh', { id: request.id, force }));
    if (!lease.id) return row(await deps.operation('lookup', { id: request.id }));
    const permissions = await deps.kws.permissions(text(lease.id), Date.parse(text(lease.requested_at)),
      lease.file_revoked_at ? Date.parse(text(lease.file_revoked_at)) + 1 : 0);
    const applied = row(await deps.operation('apply_permissions', {
      id: lease.id, revision: lease.revision, kwsRequestId: lease.kws_request_id, ...permissions,
    }));
    return applied.id ? applied : row(await deps.operation('lookup', { id: request.id }));
  }
  async function claim(token: unknown): Promise<Row> {
    const value = text(token);
    let request: Row;
    let proofExpiry: number | undefined;
    if (/^[a-f0-9]{64}$/.test(value)) {
      request = row(await deps.operation('lookup', { claimHash: await hash(value) }));
    } else {
      const match = value.match(/^device\.v1\.([A-Za-z0-9_-]{1,384})\.([a-f0-9]{64})$/);
      if (!match) throw new Rejected(403, 'Invalid setup token.');
      // Domain separation keeps device proofs distinct from parent-email hashes.
      const expected = await hmac(`device-proof:${match[1]}`, deps.parentPepper);
      if (!sameText(expected, match[2])) throw new Rejected(403, 'Invalid setup token.');
      const proof = row(JSON.parse(atob(match[1].replaceAll('-', '+').replaceAll('_', '/'))));
      if (!uuid.test(text(proof.id)) || !uuid.test(text(proof.userId)) ||
        typeof proof.expiresAt !== 'number' || proof.expiresAt <= now() ||
        proof.expiresAt > now() + 367 * 86400000) throw new Rejected(403, 'Setup token expired.');
      request = row(await deps.operation('lookup', { id: proof.id }));
      if (request.bound_user_id !== proof.userId) throw new Rejected(403, 'Device must complete setup again.');
      proofExpiry = proof.expiresAt;
    }
    if (!request.id) throw new Rejected(403, 'Setup is unavailable or expired.');
    return { ...request, ...(proofExpiry ? { deviceProofExpiresAt: proofExpiry } : {}) };
  }
  async function webhook(raw: Uint8Array, request: Request): Promise<Response> {
    // Authenticate exact raw bytes before interpreting an event or touching state.
    const allSecrets = Object.values(deps.webhookSecrets).flat();
    if (!await verifyKwsSignature(raw, request.headers.get('x-kws-signature'), allSecrets, now())) {
      throw new Rejected(401, 'Invalid webhook signature.');
    }
    const event = row(JSON.parse(new TextDecoder().decode(raw)));
    const name = text(event.name);
    const secrets = deps.webhookSecrets[name];
    if (!secrets || !await verifyKwsSignature(raw, request.headers.get('x-kws-signature'), secrets, now()) ||
      event.orgId !== deps.organizationId ||
      (name.startsWith('families:') ? event.productId !== undefined && event.productId !== deps.productId : event.productId !== deps.productId)) {
      throw new Rejected(403, 'Webhook does not belong to this integration.');
    }
    const eventTime = Date.parse(text(event.time));
    if (!Number.isFinite(eventTime) || eventTime > now() + 300000) throw new Rejected(400, 'Invalid event time.');
    const payload = row(event.payload);
    if (payload.orgId !== undefined && payload.orgId !== deps.organizationId) throw new Rejected(403, 'Wrong organization.');
    const values = Array.isArray(payload.settings) ? payload.settings : [];
    const consents = Array.isArray(payload.consents) ? payload.consents : [];
    const denied = (settingName: string) => values.some((item) => {
      const setting = row(item);
      return setting.namespace === 'ghostcopy' && setting.settingName === settingName &&
        (setting.parentLimit === false || setting.effectiveValue === false);
    }) || consents.some((item) => row(item).consentName === `ghostcopy.${settingName}` && row(item).consentedValue === false);
    const ids = name === 'families:family-group-deleted' && Array.isArray(payload.members)
      ? payload.members.map((member) => text(row(member).userId))
      : [text(payload.userId || payload.consenteeId)];
    const eventHash = await hash(new TextDecoder().decode(raw));
    // Properties of the event, not of each subject it names.
    const unlink = name === 'families:user-removed-from-family' || name === 'families:family-group-deleted';
    const cloudDenied = denied('cloudSync') || name === 'consent:deleted' || name === 'families:guardian-request-expired';
    const fileDenied = denied('fileSync');
    for (const id of [...new Set(ids)]) {
      if (!uuid.test(id)) continue;
      const subjectHash = await hash(`${eventHash}:${id}`);
      const updated = row(await deps.operation('event', {
        id, hash: subjectHash, name, eventAt: new Date(eventTime).toISOString(),
        permanent: unlink || cloudDenied, unlinkParent: unlink, cloudDenied, fileDenied,
        // Never restore a locally withdrawn request using an unrelated settings event.
        grantChange: false,
        ...(payload.consentRequestId ? { kwsRequestId: payload.consentRequestId } : {}),
      }));
      if (updated.ignored || !updated.id || updated.requires_new_consent) continue;
      await refresh(updated, true);
      await deps.operation('event_done', { hash: subjectHash });
    }
    return json({ received: true });
  }
  const handle = async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') return new Response(null, { headers });
    if (request.method !== 'POST') return json({ error: 'POST required.' }, 405);
    try {
      // Stream with a hard cap rather than trusting Content-Length.
      const reader = request.body?.getReader();
      const chunks: Uint8Array[] = [];
      let length = 0;
      if (reader) while (true) {
        const next = await reader.read();
        if (next.done) break;
        length += next.value.length;
        if (length > 65536) { await reader.cancel(); throw new Rejected(413, 'Request too large.'); }
        chunks.push(next.value);
      }
      const raw = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { raw.set(chunk, offset); offset += chunk.length; }
      if (new URL(request.url).pathname.endsWith('/webhook')) return await webhook(raw, request);
      if (length > 8192) throw new Rejected(413, 'Request too large.');
      const data = row(JSON.parse(new TextDecoder().decode(raw)));
      const action = text(data.action);
      if (action === 'configuration') {
        const config = row(await deps.operation('configuration'));
        return json({ ...config, childrenEnabled: config.childrenEnabled === true && configured(),
          parentPortalUrl: configured() ? deps.parentPortalUrl : null });
      }
      if (action === 'maintenance') {
        if (!deps.isMaintenance(request)) throw new Rejected(403, 'Forbidden.');
        const ids = await deps.operation('cleanup');
        let deleted = 0;
        if (deps.kws && Array.isArray(ids)) {
          let next = 0;
          const started = now();
          await Promise.all(Array.from({ length: Math.min(4, ids.length) }, async () => {
            while (next < ids.length && now() - started < 10000) {
              const id = ids[next++];
              try {
                await deps.kws!.deleteSubject(text(id));
                await deps.operation('deletion_done', { id });
                deleted++;
              } catch { /* The leased queue retries without logging provider personal data. */ }
            }
          }));
        }
        return json({ deleted });
      }
      if (action === 'start') {
        if (!configured()) throw new Rejected(503, 'Parent setup is not available yet.');
        const email = text(data.parentEmail).trim().toLowerCase();
        const storeRef = data.storeRef === undefined ? null : row(data.storeRef);
        if ((storeRef && !validStoreRef(storeRef.store, storeRef.id)) || !Number.isInteger(data.age) || Number(data.age) < 5 || Number(data.age) > 17 ||
          !/^[A-Z]{2}$/.test(text(data.country)) || email.length > 254 ||
          !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
          data.noticeVersion !== parentalNoticeVersion || data.noticeAcknowledged !== true) {
          throw new Rejected(400, 'Valid age, country, parent email and current notice are required.');
        }
        const token = hex(crypto.getRandomValues(new Uint8Array(32)).buffer);
        const record = row(await deps.operation('start', {
          claimHash: await hash(token), parentHash: await parentHash(email, deps.parentPepper),
          age: data.age, country: data.country, noticeVersion: parentalNoticeVersion,
        }));
        try {
          // Bound before the parent is asked, so a withdrawal through the
          // store can never miss a request it was meant to reach.
          if (storeRef) {
            const store = text(storeRef.store) as 'app_store' | 'google_play';
            await deps.storeOperation('bind', { store, requestId: record.id,
              refHash: await storeRefHash(store, text(storeRef.id), deps.parentPepper) });
          }
          const providerId = await deps.kws!.requestConsent({ consenteeId: text(record.id),
            parentEmail: email, age: Number(data.age), location: text(data.country) });
          const sent = row(await deps.operation('sent', { id: record.id, kwsRequestId: providerId }));
          return json({ ...publicRequest(sent, now()), claimToken: token });
        } catch {
          await deps.operation('remove_request', { id: record.id });
          throw new Rejected(503, 'Could not send parent verification. Please try again later.');
        }
      }
      if (action === 'poll') return json(publicRequest(await refresh(await claim(data.claimToken)), now()));
      if (action === 'cancel') {
        const pending = await claim(data.claimToken);
        const result = row(await deps.operation('cancel_request', { id: pending.id }));
        if (result.cancelled !== true) throw new Rejected(409, 'Existing accounts cannot restart parent setup.');
        return json({ cancelled: true });
      }
      const user = await deps.authenticate(request);
      if (!user) throw new Rejected(401, 'Sign in required.');
      if (action === 'authorize' || action === 'status') {
        const acknowledgeAdult = async () => row(await deps.operation('adult', { userId: user.id,
          age: data.age, country: data.country, noticeVersion: data.noticeVersion,
          termsAccepted: data.termsAccepted, privacyAcknowledged: data.privacyAcknowledged }));
        let profile = row(await deps.operation('profile', { userId: user.id }));
        if (action === 'authorize' && data.graduate === true) {
          profile = await acknowledgeAdult();
        } else if (action === 'authorize' && data.claimToken &&
            (!profile.user_id || profile.status === 'revoked')) {
          const child = await refresh(await claim(data.claimToken));
          if (publicRequest(child, now()).status !== 'authorized') throw new Rejected(403, 'Parent authorization required.');
          if (child.bound_user_id) {
            if (child.bound_user_id !== user.id) throw new Rejected(503, 'Account authorization unavailable.');
            // A refreshed device proof belongs to the existing profile, not
            // the original raw claim_hash used for first-account binding.
            profile = row(await deps.operation('profile', { userId: user.id }));
            if (!profile.user_id || profile.account_kind !== 'parent_managed') throw new Rejected(503, 'Account authorization unavailable.');
          } else {
            profile = row(await deps.operation('bind', { userId: user.id, claimHash: await hash(text(data.claimToken)) }));
          }
        } else if (profile.account_kind === 'parent_managed') {
          await refresh(row(await deps.operation('lookup', { userId: user.id })));
          profile = row(await deps.operation('profile', { userId: user.id }));
        } else if (action === 'authorize' && (!profile.user_id || profile.notice_version !== parentalNoticeVersion)) {
          profile = await acknowledgeAdult();
        }
        // Configuration only decides for an unclassified account.
        const allowed = profile.user_id ? profile.status === 'authorized' && profile.cloud_sync === true &&
          profile.notice_version === parentalNoticeVersion &&
          (profile.account_kind === 'adult' || Date.parse(text(profile.valid_until)) > now())
          : row(await deps.operation('configuration')).enforced === false;
        let updatedClaim: string | undefined;
        let child: Row = {};
        if (allowed && profile.account_kind === 'parent_managed') {
          child = row(await deps.operation('lookup', { userId: user.id }));
          if (!child.id || child.bound_user_id !== user.id) throw new Rejected(503, 'Account authorization unavailable.');
          let current: Row = {};
          try { current = await claim(data.claimToken); } catch { /* Newly linked device. */ }
          if (current.id !== child.id || (typeof current.deviceProofExpiresAt === 'number' &&
            current.deviceProofExpiresAt < now() + 30 * 86400000)) {
            updatedClaim = await deviceProof(child, deps.parentPepper, now());
          }
        }
        return json({ allowed, accountKind: profile.account_kind ?? 'unclassified',
          fileSync: allowed && (profile.file_sync === true || !profile.user_id),
          ...(updatedClaim ? { deviceClaim: updatedClaim, country: profile.country, ageAtSetup: child.age } : {}),
          validUntil: profile.valid_until ?? null, parentPortalUrl: configured() ? deps.parentPortalUrl : null });
      }
      if (action.startsWith('parent-')) {
        if (!user.emailConfirmed || !user.email) throw new Rejected(403, 'Use your verified parent email.');
        const identity = await parentHash(user.email, deps.parentPepper);
        if (action === 'parent-list') return json({ children: await deps.operation('parent_list', { parentHash: identity }) });
        if (!uuid.test(text(data.id))) throw new Rejected(400, 'Invalid account.');
        const child = row(await deps.operation('parent_lookup', { id: data.id, parentHash: identity }));
        if (!child.id) throw new Rejected(404, 'Account unavailable.');
        if (action === 'parent-export') {
          const offset = data.offset ?? 0;
          if (!Number.isInteger(offset) || Number(offset) < 0 || Number(offset) > 100000) throw new Rejected(400, 'Invalid export page.');
          return json({ noticeVersion: child.notice_version, country: child.country, ageAtSetup: child.age,
            account: publicRequest(child, now()), data: child.bound_user_id ? await deps.exportUser(text(child.bound_user_id), Number(offset)) : null });
        }
        if (action === 'parent-file') {
          if (!child.bound_user_id || !text(data.path).startsWith(`${child.bound_user_id}/`)) throw new Rejected(404, 'File unavailable.');
          return json(await deps.exportFile(text(child.bound_user_id), text(data.path)));
        }
        if (action === 'parent-revoke' || action === 'parent-delete') {
          if (data.confirm !== true) throw new Rejected(400, 'Confirmation required.');
          // Local authorization is removed first, even during a provider outage.
          await deps.operation('revoke', { id: child.id });
          if (action === 'parent-delete') {
            if (child.bound_user_id) await deps.deleteUser(text(child.bound_user_id));
            await deps.operation('remove_request', { id: child.id });
            return json({ deleted: true });
          }
          try { await deps.kws?.withdraw(text(child.id)); } catch { /* Local denial persists. */ }
          return json({ revoked: true });
        }
      }
      throw new Rejected(400, 'Unsupported action.');
    } catch (error) {
      if (error instanceof Rejected) return json({ error: error.message }, error.status);
      if (error instanceof SyntaxError) return json({ error: 'Invalid JSON.' }, 400);
      // No request body, email, credentials, signature or provider response in logs.
      return json({ error: 'Consent service unavailable. Please try again.' }, 503);
    }
  };
  return async (request: Request): Promise<Response> => {
    const response = await handle(request);
    const origin = request.headers.get('Origin');
    if (origin === 'https://ghostcopy.app' || origin === 'https://www.ghostcopy.app') {
      response.headers.set('Access-Control-Allow-Origin', origin);
    }
    response.headers.set('Vary', 'Origin');
    return response;
  };
}
