import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { after, before, beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';

// Execute the actual migration in PostgreSQL/WASM. Stub only hosted platform
// services (cron, Vault, pg_net); no network or production database is used.
const db = new PGlite();
const uid = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
before(async () => {
  await db.exec(`
    CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
    CREATE SCHEMA auth; CREATE SCHEMA cron; CREATE SCHEMA vault; CREATE SCHEMA net;
    CREATE TABLE auth.users(id uuid PRIMARY KEY, is_anonymous boolean DEFAULT false,
      created_at timestamptz DEFAULT now(), last_sign_in_at timestamptz);
    CREATE TABLE auth.sessions(id bigint GENERATED ALWAYS AS IDENTITY,
      user_id uuid REFERENCES auth.users ON DELETE CASCADE,
      created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now());
    CREATE TABLE public.clipboard(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
      created_at timestamptz NOT NULL DEFAULT now(), storage_path text);
    CREATE INDEX idx_clipboard_user_id_created_at ON public.clipboard(user_id, created_at DESC);
    CREATE TABLE public.devices(id bigint GENERATED ALWAYS AS IDENTITY,
      user_id uuid REFERENCES auth.users ON DELETE CASCADE);
    CREATE TABLE public.mobile_link_tokens(token text PRIMARY KEY,
      user_id uuid REFERENCES auth.users ON DELETE CASCADE, expires_at timestamptz);
    CREATE TABLE public.user_rate_limit(user_id uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
      insert_count integer NOT NULL, window_start timestamptz NOT NULL, updated_at timestamptz);
    CREATE TABLE cron.job(jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      jobname text UNIQUE, schedule text, command text);
    CREATE FUNCTION cron.schedule(n text, s text, c text) RETURNS bigint LANGUAGE sql AS $$
      INSERT INTO cron.job(jobname,schedule,command) VALUES(n,s,c)
      ON CONFLICT(jobname) DO UPDATE SET schedule=s,command=c RETURNING jobid;
    $$;
    CREATE FUNCTION cron.unschedule(i bigint) RETURNS boolean LANGUAGE sql AS $$
      DELETE FROM cron.job WHERE jobid=i RETURNING true;
    $$;
    INSERT INTO cron.job(jobname) VALUES('cleanup-old-clips-daily');
    CREATE TABLE vault.decrypted_secrets(name text, decrypted_secret text);
    CREATE TABLE net.requests(body jsonb);
    CREATE FUNCTION net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds integer)
    RETURNS bigint LANGUAGE plpgsql AS $$ BEGIN
      INSERT INTO net.requests VALUES(body); RETURN 1;
    END; $$;
  `);
  for (const name of [
    '20260915000000_bound_cleanup_and_rate_limits.sql',
    '20260915170000_deny_all_policies_on_service_tables.sql',
  ]) {
    await db.exec(await readFile(new URL(`../../supabase/migrations/${name}`, import.meta.url), 'utf8'));
  }
  await db.exec(`
    CREATE TRIGGER clipboard_rate_limit_check BEFORE INSERT ON public.clipboard
      FOR EACH ROW EXECUTE FUNCTION public.check_clipboard_rate_limit();
    CREATE TRIGGER cleanup_storage_after_clipboard_delete AFTER DELETE ON public.clipboard
      FOR EACH ROW EXECUTE FUNCTION public.cleanup_storage_on_clipboard_delete();
  `);
});
after(() => db.close());
beforeEach(async () => {
  await db.exec(`TRUNCATE auth.users CASCADE;
    TRUNCATE public.storage_cleanup_queue, net.requests, vault.decrypted_secrets;
    UPDATE public.clipboard_cleanup_cursor SET last_user_id=NULL;
    ALTER TABLE public.clipboard ENABLE TRIGGER clipboard_rate_limit_check;`);
  await db.query('INSERT INTO auth.users(id) VALUES($1),($2)', [uid(1), uid(2)]);
});

test('cleanup commits bounded progress and retains exactly the newest 20', async () => {
  await db.exec('ALTER TABLE public.clipboard DISABLE TRIGGER clipboard_rate_limit_check');
  await db.query(`INSERT INTO public.clipboard(user_id, storage_path)
    SELECT $1::uuid, $1 || '/' || i FROM generate_series(1,6030) i`, [uid(1)]);
  await db.query(`INSERT INTO public.clipboard(user_id)
    SELECT $1 FROM generate_series(1,25)`, [uid(2)]);
  const first = (await db.query('SELECT * FROM public.cleanup_old_clipboard_items_deep()')).rows[0];
  assert.equal(Number(first.deleted_count), 5000);
  const second = (await db.query('SELECT * FROM public.cleanup_old_clipboard_items_deep()')).rows[0];
  assert.equal(Number(second.deleted_count), 1015);
  const counts = (await db.query('SELECT user_id,count(*) FROM public.clipboard GROUP BY user_id ORDER BY user_id')).rows;
  assert.deepEqual(counts.map((r) => Number(r.count)), [20,20]);
  const remaining = (await db.query('SELECT storage_path FROM public.clipboard WHERE user_id=$1 ORDER BY id', [uid(1)])).rows;
  assert.equal(remaining[0].storage_path, `${uid(1)}/6011`);
  assert.equal(Number((await db.query('SELECT count(*) FROM public.storage_cleanup_queue')).rows[0].count), 6010);
  assert.equal(Number((await db.query('SELECT count(*) FROM net.requests')).rows[0].count), 0);
});

test('clipboard limit rejects insert 11 and admits an expired window', async () => {
  for (let i=0; i<10; i++) await db.query('INSERT INTO public.clipboard(user_id) VALUES($1)', [uid(1)]);
  await assert.rejects(db.query('INSERT INTO public.clipboard(user_id) VALUES($1)', [uid(1)]), /Rate limit exceeded/);
  assert.equal((await db.query('SELECT insert_count FROM public.user_rate_limit')).rows[0].insert_count, 10);
  await db.exec("UPDATE public.user_rate_limit SET window_start=now()-interval '2 minutes'");
  await db.query('INSERT INTO public.clipboard(user_id) VALUES($1)', [uid(1)]);
  assert.equal((await db.query('SELECT insert_count FROM public.user_rate_limit')).rows[0].insert_count, 1);
});

test('storage rate limits persist across calls and separate users/actions', async () => {
  for (let i=0; i<20; i++) {
    assert.equal((await db.query("SELECT * FROM public.check_storage_rate_limit($1, 'upload')", [uid(1)])).rows[0].allowed, true);
  }
  const denied = (await db.query("SELECT * FROM public.check_storage_rate_limit($1, 'upload')", [uid(1)])).rows[0];
  assert.equal(denied.allowed, false);
  assert.ok(denied.retry_after_seconds > 0);
  assert.equal((await db.query("SELECT * FROM public.check_storage_rate_limit($1, 'download')", [uid(1)])).rows[0].allowed, true);
  assert.equal((await db.query("SELECT * FROM public.check_storage_rate_limit($1, 'upload')", [uid(2)])).rows[0].allowed, true);
});

test('cleanup leases retry failures and survive deleted user accounts', async () => {
  await db.query('INSERT INTO public.clipboard(user_id,storage_path) VALUES($1,$2)', [uid(1), `${uid(1)}/file`]);
  await db.query('DELETE FROM auth.users WHERE id=$1', [uid(1)]);
  const first = (await db.query('SELECT * FROM public.claim_storage_cleanup_batch()')).rows;
  assert.equal(first.length, 1);
  assert.equal((await db.query('SELECT * FROM public.claim_storage_cleanup_batch()')).rows.length, 0);
  await db.exec("UPDATE public.storage_cleanup_queue SET next_attempt_at=now()-interval '1 second'");
  const retry = (await db.query('SELECT * FROM public.claim_storage_cleanup_batch()')).rows;
  assert.equal(retry[0].attempts, 2);
  await db.query('SELECT public.acknowledge_storage_cleanup($1::bigint[])', [[retry[0].id]]);
  assert.equal((await db.query('SELECT * FROM public.storage_cleanup_queue')).rows.length, 0);
});

test('privileged queue and rate RPCs are inaccessible to ordinary users', async () => {
  for (const fn of ['claim_storage_cleanup_batch()', 'check_storage_rate_limit(uuid,text)', 'acknowledge_storage_cleanup(bigint[])']) {
    const row = (await db.query("SELECT has_function_privilege('authenticated', $1, 'EXECUTE') AS allowed", [`public.${fn}`])).rows[0];
    assert.equal(row.allowed, false);
  }
  assert.equal((await db.query("SELECT has_table_privilege('authenticated', 'public.storage_cleanup_queue', 'SELECT') AS allowed")).rows[0].allowed, false);
});

test('dispatch batches HTTP calls instead of making one call per file', async () => {
  await db.exec('SELECT public.dispatch_storage_cleanup()');
  assert.equal((await db.query('SELECT * FROM net.requests')).rows.length, 0);
  await db.query(`INSERT INTO public.storage_cleanup_queue(owner_id,storage_path)
    SELECT $1::uuid,$1 || '/' || i FROM generate_series(1,5500) i`, [uid(1)]);
  await assert.rejects(db.exec('SELECT public.dispatch_storage_cleanup()'), /requires/);
  assert.equal(Number((await db.query('SELECT count(*) FROM public.storage_cleanup_queue')).rows[0].count), 5500);
  await db.exec("INSERT INTO vault.decrypted_secrets VALUES('supabase_api_url','https://example.com'),('fcm_service_role_key','test-key')");
  await db.exec('SELECT public.dispatch_storage_cleanup()');
  assert.equal((await db.query('SELECT * FROM net.requests')).rows.length, 10);
  assert.equal((await db.query('SELECT body FROM net.requests LIMIT 1')).rows[0].body.action, 'delete_queued');
});

test('expired transient rows are reaped while live QR tokens remain', async () => {
  await db.query("INSERT INTO public.mobile_link_tokens VALUES('old',$1,now()-interval '1 day'),('live',$1,now()+interval '1 hour')", [uid(1)]);
  await db.query("INSERT INTO public.user_rate_limit VALUES($1,1,now()-interval '2 days',now()-interval '2 days')", [uid(1)]);
  await db.query("INSERT INTO public.storage_rate_limits VALUES($1,'upload',1,now()-interval '2 days')", [uid(1)]);
  await db.exec('SELECT public.cleanup_stale_rate_limits()');
  assert.deepEqual((await db.query('SELECT token FROM public.mobile_link_tokens')).rows, [{token:'live'}]);
  assert.equal((await db.query('SELECT * FROM public.user_rate_limit')).rows.length, 0);
  assert.equal((await db.query('SELECT * FROM public.storage_rate_limits')).rows.length, 0);
});

test('anonymous cleanup preserves data-bearing and recently refreshed accounts', async () => {
  await db.query('INSERT INTO auth.users(id) VALUES($1),($2)', [uid(3),uid(4)]);
  await db.exec("UPDATE auth.users SET is_anonymous=true,created_at=now()-interval '60 days'");
  await db.query('INSERT INTO public.clipboard(user_id) VALUES($1)', [uid(2)]);
  await db.query('INSERT INTO auth.sessions(user_id) VALUES($1)', [uid(3)]);
  await db.query("INSERT INTO public.mobile_link_tokens VALUES('live',$1,now()+interval '1 hour')", [uid(4)]);
  await db.exec('SELECT public.cleanup_abandoned_anonymous_users()');
  assert.deepEqual((await db.query('SELECT id FROM auth.users ORDER BY id')).rows.map((r)=>r.id), [uid(2),uid(3),uid(4)]);
});

test('cron replaces the nightly job with bounded recurring work', async () => {
  const jobs = (await db.query('SELECT jobname,schedule FROM cron.job ORDER BY jobname')).rows;
  assert.equal(jobs.length, 4);
  assert.equal(jobs.some((j)=>j.jobname==='cleanup-old-clips-daily'), false);
  assert.equal(jobs.find((j)=>j.jobname==='cleanup-old-clips-bounded').schedule, '* * * * *');
});

test('service-only tables refuse every client role and keep working for service_role', async () => {
  const tables = ['clipboard_cleanup_cursor', 'storage_rate_limits', 'storage_cleanup_queue'];

  // The linter's complaint was that RLS was on with no policy. Assert the
  // policy now exists, so the INFO finding cannot come back unnoticed.
  for (const t of tables) {
    const { rows } = await db.query(
      'SELECT policyname, roles, qual FROM pg_policies WHERE schemaname=$1 AND tablename=$2', ['public', t]);
    assert.equal(rows.length, 1, `${t} should have exactly one policy`);
    assert.equal(rows[0].qual, 'false', `${t} policy should deny outright`);
    assert.deepEqual([...rows[0].roles].sort(), ['anon', 'authenticated']);
  }

  // What actually protects the tables is the missing GRANT, which bites before
  // RLS is consulted. Prove both client roles are refused outright.
  for (const role of ['anon', 'authenticated']) {
    for (const t of tables) {
      await db.exec(`SET ROLE ${role}`);
      await assert.rejects(
        db.query(`SELECT * FROM public.${t}`),
        /permission denied/i,
        `${role} should not read ${t}`);
      await db.exec('RESET ROLE');
    }
  }

  // And that the deny-all did not lock out the role the cleanup jobs run as.
  await db.exec('SET ROLE service_role');
  for (const t of tables) {
    await db.query(`SELECT * FROM public.${t}`);
  }
  await db.exec('RESET ROLE');
});
