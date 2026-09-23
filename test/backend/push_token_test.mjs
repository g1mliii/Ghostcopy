import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { before, beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';

// Runs the real claim_fcm_token migration in PostgreSQL/WASM against a
// devices table shaped like production's, with auth.uid() stubbed from a
// session setting so each test can say who is calling.
const db = new PGlite();
const uid = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const device = (n) => `10000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const TOKEN = 'f'.repeat(40) + ':APA91b-phone-registration-token';

before(async () => {
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated;
    CREATE SCHEMA auth;
    CREATE TABLE auth.users(id uuid PRIMARY KEY);
    CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
      SELECT nullif(current_setting('test.uid', true), '')::uuid
    $$;
    CREATE TABLE public.devices(
      id uuid PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
      device_name text,
      fcm_token text,
      last_active timestamptz NOT NULL DEFAULT now() - interval '1 day'
    );
    CREATE UNIQUE INDEX devices_fcm_token_global_unique
      ON public.devices(fcm_token) WHERE fcm_token IS NOT NULL;
  `);
  await db.exec(await readFile(new URL(
    '../../supabase/migrations/20260923120000_claim_fcm_token.sql', import.meta.url), 'utf8'));
});

beforeEach(async () => {
  await db.exec(`
    DELETE FROM public.devices; DELETE FROM auth.users;
    INSERT INTO auth.users VALUES ('${uid(1)}'), ('${uid(2)}');
    -- The phone's row on the account it left still holds the token.
    INSERT INTO public.devices(id, user_id, device_name, fcm_token)
      VALUES ('${device(1)}', '${uid(1)}', 'iPhone', '${TOKEN}');
    -- The same phone's row on the account it is on now has none.
    INSERT INTO public.devices(id, user_id, device_name)
      VALUES ('${device(2)}', '${uid(2)}', 'iPhone');
  `);
});

async function claimAs(user, deviceId, token = TOKEN) {
  await db.query(`SELECT set_config('test.uid', $1, false)`, [user ?? '']);
  const { rows } = await db.query('SELECT public.claim_fcm_token($1, $2) AS ok', [deviceId, token]);
  return rows[0].ok;
}

async function tokens() {
  const { rows } = await db.query('SELECT id, fcm_token, last_active FROM public.devices ORDER BY id');
  return Object.fromEntries(rows.map((r) => [r.id, r]));
}

test('the current account takes the token back from the row it left', async () => {
  assert.equal(await claimAs(uid(2), device(2)), true);
  const rows = await tokens();
  assert.equal(rows[device(2)].fcm_token, TOKEN);
  assert.equal(rows[device(1)].fcm_token, null);
  assert.ok(Date.now() - rows[device(2)].last_active.getTime() < 60_000, 'claim marks the row active');
});

test('the old account keeps its device row, just without the token', async () => {
  await claimAs(uid(2), device(2));
  assert.ok((await tokens())[device(1)], 'row is cleared, not deleted');
});

test('a token cannot be put on a row the caller does not own', async () => {
  assert.equal(await claimAs(uid(2), device(1)), false);
  const rows = await tokens();
  assert.equal(rows[device(1)].fcm_token, TOKEN);
  assert.equal(rows[device(2)].fcm_token, null);
});

test('it needs a signed-in caller', async () => {
  await assert.rejects(() => claimAs(null, device(2)), /Not signed in/);
  assert.equal((await tokens())[device(1)].fcm_token, TOKEN);
});

test('something that is not a push token clears nothing', async () => {
  await db.exec(`UPDATE public.devices SET fcm_token = 'short' WHERE id = '${device(1)}'`);
  await assert.rejects(() => claimAs(uid(2), device(2), 'short'), /Not a push token/);
  assert.equal((await tokens())[device(1)].fcm_token, 'short');
});

test('claiming a token nobody holds simply sets it', async () => {
  await db.exec(`UPDATE public.devices SET fcm_token = NULL`);
  assert.equal(await claimAs(uid(2), device(2)), true);
  assert.equal((await tokens())[device(2)].fcm_token, TOKEN);
});
