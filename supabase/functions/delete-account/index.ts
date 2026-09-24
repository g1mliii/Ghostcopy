// Deletes the signed-in user's account, from inside the app.
//
// App Review requires in-app deletion for any app where people can create an
// account (guideline 5.1.1(v)). The client cannot do it itself - deleting an
// auth user needs the service role - so it asks here, authenticated as the
// user being deleted.
//
// Deleting the auth user is the whole job: clipboard, devices,
// mobile_link_tokens and user_rate_limit are ON DELETE CASCADE, the clipboard
// AFTER DELETE trigger queues every stored file for removal from R2, and the
// passphrase's cloud backup lives in the user record itself. The same path the
// 90-day guest expiry already relies on.
//
// Sign in with Apple adds one step. Apple requires an app that offers it to
// revoke the user's Apple tokens when the account is deleted, and Supabase
// keeps no Apple refresh token to revoke. So the client has the user confirm
// with Apple once more and sends the fresh authorization code; once the
// account itself is gone, this function exchanges it for a token and revokes
// that. A revocation that fails is logged
// and does not stop the deletion: the user asked for their data to go, and
// Apple being unreachable is not a reason to keep it.

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { corsPreflight, json } from '../_shared/http.ts'

const APPLE_TEAM_ID = 'R9TKT8U45R'
const APPLE_KEY_ID = 'Y8NRLTKXG3'

/**
 * Native sign-in on iOS and macOS authenticates as the bundle ID, so codes
 * from the app's re-authorization sheet belong to it, not the Services ID.
 */
const APPLE_CLIENT_ID = 'com.ghostcopy.ghostcopy'

/** How long each Apple call may take. Revocation is best effort. */
const APPLE_TIMEOUT_MS = 5000

function base64url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * The short-lived client secret Apple's token endpoints expect: an ES256 JWT
 * signed with the Sign in with Apple key. Web Crypto signs ECDSA in the raw
 * r||s form a JWT wants, so no JWT library is needed.
 */
async function appleClientSecret(privateKeyPem: string): Promise<string> {
  const body = privateKeyPem
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '')
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const now = Math.floor(Date.now() / 1000)
  const encode = (value: unknown) =>
    base64url(new TextEncoder().encode(JSON.stringify(value)))
  const signingInput = `${encode({ alg: 'ES256', kid: APPLE_KEY_ID })}.${
    encode({
      iss: APPLE_TEAM_ID,
      iat: now,
      exp: now + 300,
      aud: 'https://appleid.apple.com',
      sub: APPLE_CLIENT_ID,
    })
  }`
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signingInput),
  )
  return `${signingInput}.${base64url(new Uint8Array(signature))}`
}

/** The `sub` claim of a JWT, without verifying it - see the caller. */
function jwtSubject(jwt: unknown): string | null {
  if (typeof jwt !== 'string') return null
  try {
    const payload = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const claims = JSON.parse(atob(payload.padEnd(Math.ceil(payload.length / 4) * 4, '=')))
    return typeof claims.sub === 'string' ? claims.sub : null
  } catch {
    return null
  }
}

/**
 * Exchange the fresh authorization code, then revoke what it yields - but
 * only if it belongs to [expectedSubject], the Apple ID on the account being
 * deleted.
 *
 * The code comes from whichever Apple ID the device is signed into, which
 * need not be the one on this GhostCopy account. Revoking without checking
 * would revoke the wrong Apple ID's authorization and leave the deleted
 * account's still active. The id_token's subject is read without verifying
 * its signature: it came straight from Apple's token endpoint, over TLS, in
 * answer to our own client secret.
 */
async function revokeAppleTokens(
  authorizationCode: string,
  privateKeyPem: string,
  expectedSubject: string,
): Promise<boolean> {
  const clientSecret = await appleClientSecret(privateKeyPem)
  const form = (fields: Record<string, string>) => ({
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(fields).toString(),
    // Each call on its own clock: a stalled appleid.apple.com must not hold
    // the response past the runtime's wall-clock limit, which the client
    // would read as a failed deletion.
    signal: AbortSignal.timeout(APPLE_TIMEOUT_MS),
  })

  const tokenResponse = await fetch(
    'https://appleid.apple.com/auth/token',
    form({
      client_id: APPLE_CLIENT_ID,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: 'authorization_code',
    }),
  )
  if (!tokenResponse.ok) {
    console.error('[delete-account] Apple token exchange failed:', tokenResponse.status)
    return false
  }
  const tokens = await tokenResponse.json()
  const subject = jwtSubject(tokens.id_token)
  if (subject !== expectedSubject) {
    console.error('[delete-account] Apple code is for a different Apple ID - not revoking')
    return false
  }
  const token = tokens.refresh_token ?? tokens.access_token
  if (!token) return false

  const revokeResponse = await fetch(
    'https://appleid.apple.com/auth/revoke',
    form({
      client_id: APPLE_CLIENT_ID,
      client_secret: clientSecret,
      token,
      token_type_hint: tokens.refresh_token ? 'refresh_token' : 'access_token',
    }),
  )
  if (!revokeResponse.ok) {
    console.error('[delete-account] Apple revoke failed:', revokeResponse.status)
  }
  return revokeResponse.ok
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return corsPreflight()
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

  // Who is asking is taken from their session, never from the body: the only
  // account this can delete is the caller's own.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
  })
  const { data: { user }, error: userError } = await userClient.auth.getUser()
  if (userError || !user) return json({ error: 'unauthorized' }, 401)

  let authorizationCode: string | null = null
  try {
    const body = await req.json()
    if (typeof body?.apple_authorization_code === 'string' && body.apple_authorization_code) {
      authorizationCode = body.apple_authorization_code
    }
  } catch {
    // No body is fine: most accounts have no Apple identity.
  }

  // null: not an Apple account. false: it is, and revocation did not happen.
  let appleRevoked: boolean | null = null
  const appleIdentity = (user.identities ?? []).find(
    (identity: { provider?: string }) => identity.provider === 'apple',
  ) as { id?: string; identity_data?: { sub?: string } } | undefined
  // Supabase keeps the Apple user ID as identity_data.sub (and as the
  // identity's id); that is what the code's id_token must match.
  const appleSubject = appleIdentity?.identity_data?.sub ?? appleIdentity?.id ?? ''

  // Delete first. Revoking first meant a failed deleteUser left the account in
  // place with its Apple authorization already gone, and a slow Apple call
  // stood between the user and the deletion they asked for.
  const admin = createClient(supabaseUrl, serviceRoleKey)
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id)
  if (deleteError) {
    console.error('[delete-account] deleteUser failed:', deleteError)
    return json({ error: 'delete_failed' }, 500)
  }

  if (appleIdentity) {
    const privateKey = Deno.env.get('APPLE_PRIVATE_KEY') ?? ''
    if (!authorizationCode || !privateKey) {
      console.error(
        `[delete-account] Apple account ${user.id} deleted without revocation:`,
        !authorizationCode ? 'no authorization code' : 'APPLE_PRIVATE_KEY unset',
      )
      appleRevoked = false
    } else {
      try {
        appleRevoked = await revokeAppleTokens(authorizationCode, privateKey, appleSubject)
      } catch (e) {
        // Includes a timeout: AbortSignal.timeout rejects the fetch.
        console.error('[delete-account] Apple revocation threw:', e)
        appleRevoked = false
      }
    }
  }

  return json({ deleted: true, apple_revoked: appleRevoked })
})
