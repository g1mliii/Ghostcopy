// Exchanges a QR link token (+ PIN) for a real Supabase session on the phone.
//
// Previous implementation was non-functional: it called admin.generateLink()
// and read `access_token`/`refresh_token` off the result. generateLink returns
// a magic LINK (action_link / email_otp / hashed_token) - never a session - so
// those fields were undefined, JSON.stringify dropped them, and the phone
// received a body with no tokens. The client then cast null to String, throwing
// a TypeError its `on Exception` handler could not catch, leaving the scanner
// spinning forever. The single-use token had already been deleted by then, so
// retrying required a brand new QR.
//
// This version:
//   * requires a PIN shown on the sending device, matched as part of the
//     atomic consume, so a photographed QR alone is useless AND a wrong PIN
//     does not burn the token
//   * redeems the generated link server-side via verifyOtp() to obtain a real
//     session
//   * gives anonymous users a synthetic confirmed email first, because
//     Supabase cannot mint a session for an account with no email
//   * verifies the minted session belongs to the token's owner before
//     returning it
//   * restores the token on any failure after consumption

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

/** Domain used to synthesise an email for anonymous accounts. */
const ANON_EMAIL_DOMAIN = 'anon.ghostcopy.app'

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  )
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? ''
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

  let consumed: { user_id: string; expires_at: string } | null = null
  let normalizedToken = ''
  let pinHash = ''

  const supabase = createClient(supabaseUrl, serviceRoleKey)

  /** Put a consumed token back so a transient failure doesn't cost the user a QR. */
  const restoreToken = async (reason: string) => {
    if (!consumed) return
    if (new Date(consumed.expires_at) <= new Date()) return
    const { error } = await supabase.from('mobile_link_tokens').insert({
      user_id: consumed.user_id,
      token: normalizedToken,
      pin_hash: pinHash,
      expires_at: consumed.expires_at,
    })
    if (error) {
      console.error(
        `[exchange-link-token] Failed to restore token after ${reason}:`,
        error.message,
      )
    }
  }

  try {
    const { token, pin } = await req.json()

    if (typeof token !== 'string' || token.trim().length === 0) {
      return json({ error: 'Missing token parameter' }, 400)
    }
    if (typeof pin !== 'string' || !/^\d{6}$/.test(pin.trim())) {
      return json({ error: 'A 6-digit PIN is required' }, 400)
    }

    normalizedToken = token.trim()
    pinHash = await sha256Hex(pin.trim())

    // 1. Atomically consume the token. Matching pin_hash here means a wrong PIN
    //    matches no row and therefore does NOT delete the token - the user can
    //    simply retype it instead of generating a new QR.
    const nowIso = new Date().toISOString()
    const { data: consumedToken, error: consumeError } = await supabase
      .from('mobile_link_tokens')
      .delete()
      .eq('token', normalizedToken)
      .eq('pin_hash', pinHash)
      .gt('expires_at', nowIso)
      .select('user_id, expires_at')
      .maybeSingle()

    if (consumeError) {
      console.error(
        '[exchange-link-token] Failed to consume token:',
        consumeError.message,
      )
      return json({ error: 'Failed to exchange token' }, 500)
    }

    if (!consumedToken) {
      // Distinguish wrong-PIN from expired/unknown so the phone can tell the
      // user which it was, without revealing whether the token exists.
      const { data: existing } = await supabase
        .from('mobile_link_tokens')
        .select('expires_at')
        .eq('token', normalizedToken)
        .maybeSingle()

      if (existing && new Date(existing.expires_at) > new Date()) {
        return json({ error: 'Incorrect PIN', code: 'invalid_pin' }, 401)
      }
      return json(
        { error: 'This code has expired or was already used', code: 'expired' },
        400,
      )
    }

    consumed = consumedToken

    // 2. Look up the account the QR belongs to.
    const { data: userData, error: userError } =
      await supabase.auth.admin.getUserById(consumed.user_id)

    if (userError || !userData.user) {
      await restoreToken('user lookup failure')
      console.log('[exchange-link-token] User not found:', userError?.message)
      return json({ error: 'User not found' }, 404)
    }

    const user = userData.user

    // 3. Supabase resolves magic links by email and cannot mint a session for
    //    an account without one. Anonymous users therefore get a synthetic,
    //    pre-confirmed address on a domain we control. This makes the account
    //    permanent - is_anonymous becomes false - which is the price of
    //    linking a device to an account that never had credentials.
    let email = user.email ?? ''
    if (!email) {
      email = `${user.id}@${ANON_EMAIL_DOMAIN}`
      const { error: updateError } = await supabase.auth.admin.updateUserById(
        user.id,
        { email, email_confirm: true },
      )
      if (updateError) {
        await restoreToken('synthetic email assignment failure')
        console.error(
          '[exchange-link-token] Could not assign synthetic email:',
          updateError.message,
        )
        return json({ error: 'Failed to prepare account for linking' }, 500)
      }
      console.log('[exchange-link-token] Assigned synthetic email to anonymous user')
    }

    // 4. Generate a magic link, then redeem it ourselves to get a session.
    const { data: linkData, error: linkError } =
      await supabase.auth.admin.generateLink({ type: 'magiclink', email })

    const hashedToken = linkData?.properties?.hashed_token
    if (linkError || !hashedToken) {
      await restoreToken('link generation failure')
      console.error(
        '[exchange-link-token] generateLink failed:',
        linkError?.message ?? 'no hashed_token in response',
      )
      return json({ error: 'Failed to generate session' }, 500)
    }

    // verifyOtp must run on a non-admin client: the service-role key bypasses
    // auth rather than establishing a session.
    const publicClient = createClient(supabaseUrl, anonKey)
    const { data: sessionData, error: verifyError } =
      await publicClient.auth.verifyOtp({
        token_hash: hashedToken,
        type: 'magiclink',
      })

    const session = sessionData?.session
    if (verifyError || !session?.access_token || !session?.refresh_token) {
      await restoreToken('otp verification failure')
      console.error(
        '[exchange-link-token] verifyOtp failed:',
        verifyError?.message ?? 'no session returned',
      )
      return json({ error: 'Failed to generate session' }, 500)
    }

    // 5. Never hand back a session for a different account than the QR named.
    if (sessionData.user?.id !== consumed.user_id) {
      console.error(
        '[exchange-link-token] Identity mismatch - refusing to issue session',
      )
      return json({ error: 'Failed to generate session' }, 500)
    }

    console.log('[exchange-link-token] Linked device for user:', consumed.user_id)

    return json({
      access_token: session.access_token,
      refresh_token: session.refresh_token,
      user: {
        id: sessionData.user.id,
        email: sessionData.user.email,
        is_anonymous: sessionData.user.is_anonymous ?? false,
      },
    })
  } catch (error) {
    await restoreToken('unexpected error')
    console.error('[exchange-link-token] Unexpected error:', error)
    return json({ error: 'Internal server error' }, 500)
  }
})
