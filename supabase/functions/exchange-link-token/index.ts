// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

Deno.serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    // Get token from request body
    const { token } = await req.json()

    if (!token) {
      return new Response(
        JSON.stringify({ error: 'Missing token parameter' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // Create Supabase admin client
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // 1. Verify token exists in database and is not expired
    const { data: linkData, error: linkError } = await supabase
      .from('mobile_link_tokens')
      .select('user_id, expires_at')
      .eq('token', token)
      .single()

    if (linkError || !linkData) {
      console.log('[exchange-link-token] Token not found:', linkError?.message)
      return new Response(
        JSON.stringify({ error: 'Invalid token' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // 2. Check if token has expired
    const expiresAt = new Date(linkData.expires_at)
    const now = new Date()

    if (expiresAt < now) {
      console.log('[exchange-link-token] Token expired:', {
        expiresAt,
        now,
      })
      return new Response(
        JSON.stringify({ error: 'Token expired' }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // 3. Get user details
    const { data: userData, error: userError } =
      await supabase.auth.admin.getUserById(linkData.user_id)

    if (userError || !userData.user) {
      console.log('[exchange-link-token] User not found:', userError?.message)
      return new Response(
        JSON.stringify({ error: 'User not found' }),
        {
          status: 404,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    const user = userData.user

    // 4. Generate new session for mobile device
    // Use magic link generation which returns session tokens
    const { data: linkGenData, error: linkGenError } =
      await supabase.auth.admin.generateLink({
        type: 'magiclink',
        // For anonymous users, use a pseudo-email based on user_id
        email: user.email || `${user.id}@anonymous.ghostcopy.app`,
      })

    if (linkGenError || !linkGenData) {
      console.log(
        '[exchange-link-token] Failed to generate session:',
        linkGenError?.message
      )
      return new Response(
        JSON.stringify({ error: 'Failed to generate session' }),
        {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        }
      )
    }

    // 5. Delete the token (single-use) - fire and forget
    supabase.from('mobile_link_tokens').delete().eq('token', token).then()

    // 6. Return session tokens to mobile app
    console.log('[exchange-link-token] Successfully exchanged token for user:', {
      user_id: user.id,
      is_anonymous: user.is_anonymous,
    })

    return new Response(
      JSON.stringify({
        access_token: linkGenData.properties.access_token,
        refresh_token: linkGenData.properties.refresh_token,
        user: {
          id: user.id,
          email: user.email,
          is_anonymous: user.is_anonymous,
        },
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  } catch (error) {
    console.error('[exchange-link-token] Unexpected error:', error)
    return new Response(
      JSON.stringify({
        error: 'Internal server error',
        message: error.message,
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      }
    )
  }
})

/* To invoke locally:

  1. Run `supabase start` (see: https://supabase.com/docs/reference/cli/supabase-start)
  2. Make an HTTP request:

  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/exchange-link-token' \
    --header 'Authorization: Bearer YOUR_ANON_KEY' \
    --header 'Content-Type: application/json' \
    --data '{"token":"your_token_hash"}'

*/
