// Windows Push Notification Services, for packaged Windows desktops.
//
// The desktop asks Windows for a channel URI with
// PushNotificationChannelManager (windows/runner/push_channel.cpp) and stores
// it in devices.wns_channel_uri. A raw notification to that URI wakes the
// running app, which then fetches the clip itself: the payload carries only
// the clipboard row id, never content.
//
// Authentication is the Partner Center flow that channel API pairs with: the
// app's Package SID and client secret, exchanged at login.live.com for a
// bearer token valid for about a day. Both come from the Store listing
// (Product management > WNS/MPNS / Product identity). Set them as the
// WNS_PACKAGE_SID and WNS_CLIENT_SECRET function secrets; without them
// Windows devices are skipped and keep receiving over realtime.

const TOKEN_URL = 'https://login.live.com/accesstoken.srf';

// Re-read a little before the server says it expires.
const TOKEN_MARGIN_MS = 5 * 60 * 1000;

// The request in flight is cached, not just its result: a clip for several
// Windows desktops sends to them all at once, and on a cold instance each
// would otherwise ask login.live.com for its own token.
let cachedToken: Promise<{ value: string; expiresAt: number }> | null = null;

export function wnsConfigured(): boolean {
  return Boolean(Deno.env.get('WNS_PACKAGE_SID') && Deno.env.get('WNS_CLIENT_SECRET'));
}

// A channel URI is POSTed to with a bearer token, so only WNS's own hosts are
// ever sent to - the database constraint says the same, and this holds even
// if a row predates it or the constraint is dropped.
export function isWnsChannelUri(value: unknown): value is string {
  if (typeof value !== 'string' || value.length > 2048) return false;
  try {
    const url = new URL(value);
    return url.protocol === 'https:' &&
      (url.hostname === 'notify.windows.com' || url.hostname.endsWith('.notify.windows.com'));
  } catch {
    return false;
  }
}

async function accessToken(forceRefresh: boolean): Promise<string> {
  if (!forceRefresh && cachedToken) {
    try {
      const token = await cachedToken;
      if (token.expiresAt - TOKEN_MARGIN_MS > Date.now()) return token.value;
    } catch {
      // A failed request is not reused; ask again below.
    }
  }
  const request = requestToken();
  cachedToken = request;
  try {
    return (await request).value;
  } catch (error) {
    if (cachedToken === request) cachedToken = null;
    throw error;
  }
}

async function requestToken(): Promise<{ value: string; expiresAt: number }> {
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: Deno.env.get('WNS_PACKAGE_SID') ?? '',
    client_secret: Deno.env.get('WNS_CLIENT_SECRET') ?? '',
    scope: 'notify.windows.com',
  });
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!response.ok) {
    // The body names the cause (invalid_client and the like) but never holds
    // the secret.
    const detail = (await response.text()).slice(0, 200);
    throw new Error(`WNS token request failed: ${response.status} ${detail}`);
  }
  const json = await response.json();
  const expiresIn = Number(json.expires_in ?? 86400);
  return {
    value: String(json.access_token),
    expiresAt: Date.now() + expiresIn * 1000,
  };
}

export type WnsResult =
  | { ok: true }
  // gone: the channel expired or the app was uninstalled - stop sending to it.
  | { ok: false; gone: boolean; code: string; message: string };

async function post(uri: string, payload: string, token: string): Promise<Response> {
  const bytes = new TextEncoder().encode(payload);
  return await fetch(uri, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(bytes.length),
      'X-WNS-Type': 'wns/raw',
      // A clip is only worth delivering while it is new. Not cached: a raw
      // notification to an app that is not running has nothing to wake, and
      // the desktop catches up on launch anyway.
      'X-WNS-Cache-Policy': 'no-cache',
    },
    body: bytes,
  });
}

/** Send one raw "a clip arrived" ping to a Windows desktop. */
export async function sendWnsRaw(uri: string, clipboardId: string): Promise<WnsResult> {
  if (!isWnsChannelUri(uri)) {
    return { ok: false, gone: true, code: 'invalid-channel', message: 'Not a WNS channel URI' };
  }
  const payload = JSON.stringify({ clipboard_id: clipboardId });
  try {
    let response = await post(uri, payload, await accessToken(false));
    if (response.status === 401) {
      // Expired token: fetch a new one once.
      await response.body?.cancel();
      response = await post(uri, payload, await accessToken(true));
    }
    if (response.ok) {
      await response.body?.cancel();
      return { ok: true };
    }
    const status = response.status;
    const notification = response.headers.get('X-WNS-NotificationStatus') ?? '';
    await response.body?.cancel();
    return {
      ok: false,
      // 410: the channel expired. 404: not a valid channel.
      gone: status === 410 || status === 404,
      code: `wns/${status}`,
      message: notification,
    };
  } catch (error) {
    return {
      ok: false,
      gone: false,
      code: 'wns/request-failed',
      message: String((error as Error)?.message ?? error).slice(0, 200),
    };
  }
}
