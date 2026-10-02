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

/**
 * A key variable, parsed once: the environment does not change within an
 * isolate, and parsing per call logged a bad value on every request.
 * `present` is whether the variable is set at all, which is not the same as
 * holding a usable key - a value that is set but malformed must not be
 * mistaken for "running locally" and let the legacy key back in.
 */
function named(variable: string): { present: boolean; keys: string[]; preferred?: string } {
  const raw = Deno.env.get(variable)
  if (!raw) return { present: false, keys: [] }
  try {
    const parsed = JSON.parse(raw)
    if (parsed === null || typeof parsed !== 'object') throw new Error('not an object')
    const entries = Object.entries(parsed).filter(
      (entry): entry is [string, string] =>
        typeof entry[1] === 'string' && entry[1].length > 0,
    )
    if (entries.length === 0) throw new Error('no keys')
    const keys = entries.map(([, key]) => key)
    const preferred = entries.find(([name]) => name === 'default')?.[1] ?? keys[0]
    return { present: true, keys, preferred }
  } catch (e) {
    console.error(`[keys] ${variable} is set but holds no usable key: ${e}`)
    return { present: true, keys: [] }
  }
}

const publishable = named('SUPABASE_PUBLISHABLE_KEYS')
const secret = named('SUPABASE_SECRET_KEYS')
const legacyServiceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

/**
 * Whether a key is from the current scheme. In this project the platform
 * already injects an `sb_secret_...` key as SUPABASE_SERVICE_ROLE_KEY, and
 * the trigger's vault secret matches it; a key in that form is revoked on its
 * own, not by the legacy switch, so it is safe to accept where a legacy JWT
 * is not.
 */
const isCurrentSchemeSecret = (key: string) => key.startsWith('sb_secret_')

const warned = new Set<string>()

function pick(current: { keys: string[]; preferred?: string }, legacy: string): string {
  if (current.preferred) return current.preferred
  const fallback = Deno.env.get(legacy) ?? ''
  // Expected under local serve. In production it means the new variables are
  // missing, and everything here stops the day the legacy keys are disabled -
  // said once per isolate, so it is visible without flooding the logs.
  if (fallback && !warned.has(legacy)) {
    warned.add(legacy)
    console.warn(`[keys] falling back to ${legacy}; the current API key variables are not set`)
  }
  return fallback
}

/** For a client acting as the caller: their session decides what it sees. */
export function publishableKey(): string {
  return pick(publishable, 'SUPABASE_ANON_KEY')
}

/** For a client that bypasses RLS. Never sent back to a caller. */
export function secretKey(): string {
  return pick(secret, 'SUPABASE_SERVICE_ROLE_KEY')
}

/**
 * Whether the request carries one of the project's secret keys - how the
 * database triggers authenticate over pg_net. Any named secret key counts,
 * not only `default`, so the vault secret the triggers send can be rotated to
 * a new key before the old one is revoked.
 *
 * SUPABASE_SERVICE_ROLE_KEY counts when it is itself an `sb_secret_...` key,
 * or when no current secret keys are configured at all (local serve). A
 * legacy JWT there does not count once current keys are configured: Supabase
 * can go on injecting it after it has been disabled, and
 * send-clipboard-notification and storage-presign skip the platform's JWT
 * gate - accepting it would leave a revoked key able to act as the trigger.
 */
export function isSecretKeyCaller(authorization: string | null): boolean {
  if (!authorization?.startsWith('Bearer ')) return false
  const presented = authorization.slice('Bearer '.length)
  if (!presented) return false
  const accepted = [...secret.keys]
  if (legacyServiceRole &&
      (!secret.present || isCurrentSchemeSecret(legacyServiceRole))) {
    accepted.push(legacyServiceRole)
  }
  if (accepted.some((key) => timingSafeEqual(presented, key))) return true
  // The one failure that is otherwise silent: the trigger still sending the
  // legacy key, which now falls through to a user check and a bare 401.
  if (legacyServiceRole && timingSafeEqual(presented, legacyServiceRole)) {
    console.error('[keys] refused the legacy service-role key as a trigger; ' +
      'the fcm_service_role_key vault secret must be one of SUPABASE_SECRET_KEYS')
  }
  return false
}

function timingSafeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a)
  const right = new TextEncoder().encode(b)
  if (left.length !== right.length) return false
  let difference = 0
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i]
  return difference === 0
}
