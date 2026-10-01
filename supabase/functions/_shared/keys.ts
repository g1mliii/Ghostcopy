// The project's API keys, read the way Supabase's current key scheme hands
// them to functions.
//
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are the legacy keys. Once
// they are disabled in the dashboard, anything still built from them fails
// with "Legacy API keys are disabled" - for these functions, every sign-in
// check and every trigger-driven push. The current keys arrive as JSON
// objects keyed by name in SUPABASE_PUBLISHABLE_KEYS and SUPABASE_SECRET_KEYS;
// the dashboard's first key of each kind is named `default`.
//
// The legacy variables stay as a fallback for local `supabase functions
// serve`, which may not set the new ones.

function named(variable: string): Record<string, string> {
  const raw = Deno.env.get(variable)
  if (!raw) return {}
  try {
    const parsed = JSON.parse(raw)
    if (parsed === null || typeof parsed !== 'object') return {}
    return Object.fromEntries(
      Object.entries(parsed).filter(
        (entry): entry is [string, string] =>
          typeof entry[1] === 'string' && entry[1].length > 0,
      ),
    )
  } catch {
    console.error(`[keys] ${variable} is not JSON`)
    return {}
  }
}

function pick(keys: Record<string, string>, legacy: string): string {
  return keys['default'] ?? Object.values(keys)[0] ?? Deno.env.get(legacy) ?? ''
}

/** For a client acting as the caller: their session decides what it sees. */
export function publishableKey(): string {
  return pick(named('SUPABASE_PUBLISHABLE_KEYS'), 'SUPABASE_ANON_KEY')
}

/** For a client that bypasses RLS. Never sent back to a caller. */
export function secretKey(): string {
  return pick(named('SUPABASE_SECRET_KEYS'), 'SUPABASE_SERVICE_ROLE_KEY')
}

/**
 * Whether the request carries one of the project's secret keys - how the
 * database triggers authenticate over pg_net. Any named secret key counts,
 * not only `default`, so the vault secret the triggers send can be rotated to
 * a new key before the old one is revoked. The legacy service-role key counts
 * until it is disabled.
 */
export function isSecretKeyCaller(authorization: string | null): boolean {
  if (!authorization?.startsWith('Bearer ')) return false
  const presented = authorization.slice('Bearer '.length)
  if (!presented) return false
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const accepted = [
    ...Object.values(named('SUPABASE_SECRET_KEYS')),
    ...(legacy ? [legacy] : []),
  ]
  return accepted.some((key) => timingSafeEqual(presented, key))
}

function timingSafeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a)
  const right = new TextEncoder().encode(b)
  if (left.length !== right.length) return false
  let difference = 0
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i]
  return difference === 0
}
