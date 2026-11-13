// KWS contracts verified against the signed-in User Permissions API reference
// and the public webhook-signature documentation. Credentials stay server-side.
export const parentalNoticeVersion = '2026-11-12-v3';
export const kwsNamespace = 'ghostcopy';
export const kwsSettings = ['cloudSync', 'fileSync'] as const;

export interface KwsConfig {
  clientId: string;
  clientSecret: string;
  productId: string;
  organizationId: string;
  apiBaseUrl: string;
}

export interface KwsPermissions {
  cloudSync: boolean;
  fileSync: boolean;
}

export class KwsUnavailableError extends Error {
  constructor() {
    super('Parental consent service is unavailable. Please try again later.');
    this.name = 'KwsUnavailableError';
  }
}

function object(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown> : null;
}

/** Accept multiple active signatures/secrets during KWS secret rotation. */
export async function verifyKwsSignature(
  rawBody: Uint8Array,
  header: string | null,
  secrets: readonly string[],
  now = Date.now(),
): Promise<boolean> {
  if (!header || header.length > 2048 || rawBody.length > 65536 ||
      !secrets.length || secrets.some((secret) => !secret)) return false;
  let timestamp: string | undefined;
  const signatures: string[] = [];
  for (const field of header.split(',')) {
    const [key, value, extra] = field.trim().split('=');
    if (extra !== undefined || !value) return false;
    if (key === 't') {
      if (timestamp !== undefined) return false;
      timestamp = value;
    } else if (key === 'v1') {
      if (!/^[a-f\d]{64}$/i.test(value)) return false;
      signatures.push(value);
    } else {
      return false;
    }
  }
  if (!timestamp || !/^\d{10}(?:\d{3})?$/.test(timestamp) ||
      signatures.length === 0 || signatures.length > 8) return false;
  // The PV reference uses milliseconds; normalize a Unix-seconds timestamp
  // too, while preserving the exact signed text for HMAC verification.
  const timestampMs = Number(timestamp) * (timestamp.length === 10 ? 1000 : 1);
  if (!Number.isFinite(timestampMs) || Math.abs(now - timestampMs) > 300000) {
    return false;
  }
  const prefix = new TextEncoder().encode(`${timestamp}.`);
  const signed = new Uint8Array(prefix.length + rawBody.length);
  signed.set(prefix);
  signed.set(rawBody, prefix.length);
  for (const secret of secrets) {
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'],
    );
    for (const signature of signatures) {
      const bytes = Uint8Array.from(
        signature.match(/../g)!, (pair) => Number.parseInt(pair, 16),
      );
      if (await crypto.subtle.verify('HMAC', key, bytes, signed)) return true;
    }
  }
  return false;
}

/** A configured HTTPS host under Epic's KWS domain; no arbitrary fetch targets. */
export function validatedKwsBase(value: string): URL {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port ||
      url.search || url.hash || url.pathname !== '/' ||
      !(url.hostname === 'kidswebservices.com' ||
        url.hostname.endsWith('.kidswebservices.com'))) {
    throw new KwsUnavailableError();
  }
  return url;
}

/** Uses exact documented endpoints. No API keys or developer tokens reach Flutter. */
export class KwsClient {
  private token: string | null = null;
  private tokenExpiresAt = 0;
  private tokenRequest: Promise<string> | null = null;
  private readonly base: URL;

  constructor(
    private readonly config: KwsConfig,
    private readonly fetcher: typeof fetch = fetch,
    private readonly now: () => number = Date.now,
  ) {
    this.base = validatedKwsBase(config.apiBaseUrl);
    if (![config.clientId, config.clientSecret, config.productId,
      config.organizationId].every((value) => value.length > 0)) {
      throw new KwsUnavailableError();
    }
  }

  private async accessToken(): Promise<string> {
    if (this.token && this.tokenExpiresAt > this.now() + 60000) return this.token;
    if (this.tokenRequest) return this.tokenRequest;
    this.tokenRequest = (async () => {
      const credentials = new TextEncoder().encode(
        `${this.config.clientId}:${this.config.clientSecret}`,
      );
      const response = await this.fetcher(
        'https://auth.kidswebservices.com/auth/realms/kws/protocol/openid-connect/token',
        {
          method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000),
          headers: {
            'Authorization': `Basic ${btoa(String.fromCharCode(...credentials))}`,
            'Content-Type': 'application/x-www-form-urlencoded',
            'User-Agent': 'GhostCopy-Consent/1.0',
          },
          body: new URLSearchParams({
            grant_type: 'client_credentials', scope: 'settings consent family',
          }),
        },
      );
      if (!response.ok) throw new KwsUnavailableError();
      const result = object(await response.json());
      if (typeof result?.access_token !== 'string' ||
          typeof result.expires_in !== 'number' || result.expires_in <= 0) {
        throw new KwsUnavailableError();
      }
      this.token = result.access_token;
      this.tokenExpiresAt = this.now() + result.expires_in * 1000;
      return this.token;
    })();
    try {
      return await this.tokenRequest;
    } finally {
      this.tokenRequest = null;
    }
  }

  private async request(path: string, method: string, body?: unknown): Promise<unknown> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const response = await this.fetcher(new URL(path, this.base), {
        method, redirect: 'error', signal: AbortSignal.timeout(10000),
        headers: {
          'Authorization': `Bearer ${await this.accessToken()}`,
          'Content-Type': 'application/json', 'Accept': 'application/json',
          'User-Agent': 'GhostCopy-Consent/1.0',
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      if (response.status === 401 && attempt === 0) {
        this.token = null;
        await response.body?.cancel();
        continue;
      }
      // Subject erasure is idempotent, including a retry after the first
      // request committed but its response was lost.
      if (method === 'DELETE' && (response.ok || response.status === 404)) {
        await response.body?.cancel();
        return null;
      }
      if (!response.ok) throw new KwsUnavailableError();
      return response.status === 204 ? null : response.json();
    }
    throw new KwsUnavailableError();
  }

  async requestConsent(input: {
    consenteeId: string; parentEmail: string; age: number; location: string;
  }): Promise<string> {
    const result = object(await this.request(
      `/v1/settings/admin/users/${encodeURIComponent(input.consenteeId)}` +
        `/products/${encodeURIComponent(this.config.productId)}/send-consent-email`,
      'POST', {
        age: input.age, ageProvidedAt: Math.floor(this.now() / 1000),
        location: input.location, parentEmail: input.parentEmail, language: 'en',
        displayName: `GhostCopy account ${input.consenteeId.slice(-6)}`,
        enforceParentalControl: true,
        settings: kwsSettings.map((settingName) => ({ namespace: kwsNamespace, settingName })),
      },
    ));
    const payload = object(result?.response);
    if (typeof payload?.consentRequestId !== 'string' || !payload.consentRequestId) {
      throw new KwsUnavailableError();
    }
    return payload.consentRequestId;
  }

  async permissions(consenteeId: string, consentRequestedAfter = 0, fileRequestedAfter = 0): Promise<KwsPermissions> {
    const path = `/v1/settings/users/${encodeURIComponent(consenteeId)}` +
      `/products/${encodeURIComponent(this.config.productId)}/values` +
      `?namespace=${kwsNamespace}&format=full`;
    const payload = object(object(await this.request(path, 'GET'))?.response);
    if (!Array.isArray(payload?.settings)) throw new KwsUnavailableError();
    const values: KwsPermissions = { cloudSync: false, fileSync: false };
    const seen = new Set<string>();
    for (const item of payload.settings) {
      const setting = object(item);
      if (setting?.namespace !== kwsNamespace ||
          !kwsSettings.includes(setting.settingName as typeof kwsSettings[number])) continue;
      const name = setting.settingName as keyof KwsPermissions;
      if (seen.has(name)) throw new KwsUnavailableError();
      seen.add(name);
      const bracket = object(object(setting.definition)?.ageBracket);
      // The YAML documentation calls this opt-in-verified; the API/webhook
      // reference also uses opt-in-vpc. Neither unverified consent nor an
      // inherited/default parent limit is evidence of a new parent's choice.
      values[name] = setting.effectiveValue === true && setting.parentLimit === true &&
        (bracket?.consentType === 'opt-in-vpc' || bracket?.consentType === 'opt-in-verified') &&
        typeof setting.parentLimitUpdatedAt === 'number' &&
        setting.parentLimitUpdatedAt > 0 &&
        setting.parentLimitUpdatedAt >= Math.max(consentRequestedAfter, name === 'fileSync' ? fileRequestedAfter : 0) &&
        setting.parentLimitUpdatedAt <= this.now() + 300000;
    }
    if (!seen.has('cloudSync')) throw new KwsUnavailableError();
    return values;
  }

  async deleteSubject(consenteeId: string): Promise<void> {
    await this.request(
      `/v1/settings/admin/users/${encodeURIComponent(consenteeId)}/values`, 'DELETE',
    );
  }

  async withdraw(consenteeId: string): Promise<void> {
    for (const settingName of kwsSettings) {
      await this.request(
        `/v1/settings/users/${encodeURIComponent(consenteeId)}` +
          `/products/${encodeURIComponent(this.config.productId)}/limits`,
        'PATCH', { settings: { namespace: kwsNamespace, settingName, parentLimit: false } },
      );
    }
  }
}
