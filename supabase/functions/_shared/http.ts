// Shared HTTP plumbing for the edge functions.
//
// Every function used to re-spell the same JSON response inline - roughly two
// dozen copies of `new Response(JSON.stringify(...), { status, headers: {
// ...corsHeaders, 'Content-Type': 'application/json' } })` - and each copy was
// a chance to forget the CORS headers on one error path.

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
}

/** A JSON response carrying the CORS headers every caller needs. */
export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/** The preflight response for `OPTIONS`. */
export function corsPreflight(): Response {
  return new Response('ok', { headers: corsHeaders })
}
