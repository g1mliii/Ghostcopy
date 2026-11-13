import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { before, after, beforeEach, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { setupConsentDatabase } from './consent_fixture.mjs';

const db = new PGlite();
const user = '00000000-0000-0000-0000-000000000001';
const other = '00000000-0000-0000-0000-000000000002';
before(async () => {
  await setupConsentDatabase(db);
});
after(() => db.close());
beforeEach(async () => {
  await db.exec(`RESET ROLE; SELECT set_config('request.jwt.claim.sub','',false);
    TRUNCATE auth.users CASCADE;
    TRUNCATE private.parental_consent_requests,private.consent_events,private.consent_rate_limits,private.consent_audit,private.kws_deletion_queue;
    UPDATE private.cloud_consent_settings SET enforce_all_accounts=true,child_consent_enabled=false;
    INSERT INTO auth.users(id) VALUES('${user}'),('${other}');`);
});
async function authorization(kind = 'adult', { file = true, expired = false, status = 'authorized' } = {}) {
  await db.query(`INSERT INTO public.cloud_authorizations(user_id,account_kind,country,notice_version,
      status,cloud_sync,file_sync,valid_until)
    VALUES($1,$2,'CA','2026-11-12-v3',$3,true,$4,now()+($5::int * interval '1 minute'))`,
  [user, kind, status, file, expired ? -1 : 15]);
}
async function asUser(query, params = [], id = user) {
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)", [id]);
  await db.exec('SET ROLE authenticated');
  try { return await db.query(query, params); }
  finally { await db.exec('RESET ROLE'); }
}

test('unclassified accounts cannot use current, legacy or direct partition paths', async () => {
  for (const table of ['clipboard','clipboard_test','clipboard_p0']) {
    await db.query(`INSERT INTO public.${table}(user_id,content) VALUES($1,'private')`, [user]);
    assert.equal((await asUser(`SELECT * FROM public.${table}`)).rows.length, 0);
    await assert.rejects(asUser(`INSERT INTO public.${table}(user_id,content) VALUES($1,'blocked')`, [user]), /row-level security/);
  }
  await assert.rejects(asUser('INSERT INTO public.devices(user_id) VALUES($1)', [user]), /row-level security/);
  await assert.rejects(asUser("INSERT INTO public.mobile_link_tokens VALUES('secret',$1)", [user]), /row-level security/);
  await assert.rejects(asUser("INSERT INTO public.clipboard_content VALUES(1,'legacy bypass')"), /row-level security/);
});

test('an acknowledged adult retains ordinary cloud access without gaining other accounts', async () => {
  await authorization();
  await asUser("INSERT INTO public.clipboard(user_id,content) VALUES($1,'adult clip')", [user]);
  assert.equal((await asUser('SELECT content FROM public.clipboard')).rows[0].content, 'adult clip');
  assert.equal((await asUser('SELECT * FROM public.clipboard', [], other)).rows.length, 0);
  assert.equal((await asUser("SELECT public.claim_fcm_token(gen_random_uuid(),'token') AS ok")).rows[0].ok, true);
});

test('parent-managed accounts require encryption and scoped file permission', async () => {
  await authorization('parent_managed', { file: false });
  await assert.rejects(asUser("INSERT INTO public.clipboard(user_id,content) VALUES($1,'plaintext')", [user]), /row-level security/);
  await asUser("INSERT INTO public.clipboard(user_id,content,is_encrypted) VALUES($1,'ciphertext',true)", [user]);
  await assert.rejects(asUser("INSERT INTO public.clipboard(user_id,content,is_encrypted,storage_path) VALUES($1,'ciphertext',true,'file')", [user]), /row-level security/);
  await assert.rejects(asUser("INSERT INTO public.clipboard_content VALUES(1,'legacy path')"), /row-level security/);
  await db.exec(`UPDATE public.cloud_authorizations SET file_sync=true`);
  await asUser("INSERT INTO public.clipboard(user_id,content,is_encrypted,storage_path) VALUES($1,'ciphertext',true,'file')", [user]);
});

test('expired or revoked authorization blocks data and SECURITY DEFINER token claims', async () => {
  for (const values of [{ expired: true }, { status: 'revoked' }]) {
    await db.exec('DELETE FROM public.cloud_authorizations');
    await authorization('parent_managed', values);
    assert.equal((await asUser('SELECT public.has_cloud_access() AS ok')).rows[0].ok, false);
    await assert.rejects(asUser("SELECT public.claim_fcm_token(gen_random_uuid(),'token')"), /authorization required/);
    await assert.rejects(asUser("SELECT public.claim_wns_channel(gen_random_uuid(),'uri')"), /authorization required/);
  }
});

test('client roles cannot forge authorizations or reach private evidence', async () => {
  await authorization();
  await assert.rejects(asUser("UPDATE public.cloud_authorizations SET account_kind='adult',file_sync=true"), /permission denied/);
  await assert.rejects(asUser("INSERT INTO public.cloud_authorizations(user_id,account_kind,country,notice_version,status) VALUES($1,'adult','US','2026-11-12-v3','authorized')", [other]), /permission denied/);
  await assert.rejects(asUser('SELECT * FROM private.parental_consent_requests'), /permission denied/);
  await assert.rejects(asUser("SELECT private.claim_fcm_token(gen_random_uuid(),'bypass')"), /permission denied/);
  assert.equal((await asUser('SELECT * FROM public.cloud_authorizations')).rows.length, 1);
  assert.equal((await asUser('SELECT * FROM public.cloud_authorizations', [], other)).rows.length, 0);
});

test('deleting an authorized child queues provider erasure without retaining contact addresses', async () => {
  await authorization('parent_managed');
  const request = (await db.query(`INSERT INTO private.parental_consent_requests(claim_hash,parent_hash,age,country,notice_version,bound_user_id)
    VALUES($1,$2,8,'CA','2026-11-12-v3',$3) RETURNING id`, ['a'.repeat(64),'b'.repeat(64),user])).rows[0];
  await db.query('DELETE FROM auth.users WHERE id=$1', [user]);
  assert.equal((await db.query('SELECT * FROM private.parental_consent_requests')).rows.length, 0);
  assert.equal((await db.query('SELECT subject_id FROM private.kws_deletion_queue')).rows[0].subject_id, request.id);
});

test('staging preserves unknown clients but never bypasses a classified child', async () => {
  await db.exec('UPDATE private.cloud_consent_settings SET enforce_all_accounts=false');
  assert.equal((await asUser('SELECT public.has_cloud_access() AS ok')).rows[0].ok, true);
  assert.equal((await asUser('SELECT public.has_cloud_file_access() AS ok')).rows[0].ok, true);
  await assert.rejects(db.exec('UPDATE private.cloud_consent_settings SET child_consent_enabled=true'), /check constraint/);
  await authorization('parent_managed', { expired: true });
  assert.equal((await asUser('SELECT public.has_cloud_access() AS ok')).rows[0].ok, false);
});

async function operation(action, data = {}) {
  return (await db.query('SELECT public.consent_service($1,$2::jsonb) AS result',
    [action,JSON.stringify(data)])).rows[0].result;
}
async function pending() {
  await db.exec('UPDATE private.cloud_consent_settings SET child_consent_enabled=true');
  const request = await operation('start', { claimHash:'c'.repeat(64), parentHash:'d'.repeat(64),
    age:8,country:'CA',noticeVersion:'2026-11-12-v3' });
  return operation('sent', { id:request.id,kwsRequestId:'provider-request' });
}
test('a child claim cannot bind before verified permissions and cannot become adult', async () => {
  const request = await pending();
  await assert.rejects(operation('bind',{ claimHash:request.claim_hash,userId:user }), /authorization required/);
  const approved = await operation('apply_permissions',{ id:request.id,revision:request.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:false });
  assert.equal(approved.status,'authorized');
  const bound = await operation('bind',{ claimHash:request.claim_hash,userId:user });
  assert.equal(bound.account_kind,'parent_managed');
  assert.equal(bound.file_sync,false);
  await assert.rejects(operation('bind',{ claimHash:request.claim_hash,userId:other }), /authorization required/);
  await assert.rejects(operation('adult',{ userId:user,age:18,country:'CA',noticeVersion:'2026-11-12-v3',
    termsAccepted:true,privacyAcknowledged:true }), /Parent authorization required/);
  await assert.rejects(asUser("SELECT public.consent_service('apply_permissions','{}')"), /permission denied/);
});

test('stale provider reads cannot resurrect a revoked authorization', async () => {
  const request = await pending();
  const approved = await operation('apply_permissions',{ id:request.id,revision:request.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true });
  await operation('bind',{ claimHash:request.claim_hash,userId:user });
  const snapshot = await operation('lookup',{ id:request.id });
  await db.query("INSERT INTO public.devices(user_id,fcm_token,wns_channel_uri) VALUES($1,'push','uri')",[user]);
  await operation('revoke',{ id:request.id });
  assert.equal(await operation('apply_permissions',{ id:request.id,revision:snapshot.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true }),null);
  const latest = await operation('lookup',{ id:request.id });
  assert.equal(latest.status,'revoked');
  assert.equal(await operation('apply_permissions',{ id:request.id,revision:latest.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true }),null);
  assert.equal((await db.query('SELECT fcm_token,wns_channel_uri FROM public.devices')).rows[0].fcm_token,null);
  assert.ok(approved.approved_at);
});

test('parents are scoped to their verified contact and pending requests expire', async () => {
  const request = await pending();
  await operation('apply_permissions',{ id:request.id,revision:request.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:false });
  assert.equal((await operation('parent_list',{ parentHash:request.parent_hash })).length,1);
  assert.deepEqual(await operation('parent_list',{ parentHash:'e'.repeat(64) }),[]);
  assert.equal(await operation('parent_lookup',{ id:request.id,parentHash:'e'.repeat(64) }),null);
  await db.query("UPDATE private.parental_consent_requests SET expires_at=now()-interval '1 second' WHERE id=$1",[request.id]);
  await assert.rejects(operation('bind',{ claimHash:request.claim_hash,userId:user }), /authorization required/);
  const claimed = await operation('cleanup');
  assert.deepEqual(claimed,[request.id]);
  assert.deepEqual(await operation('cleanup'),[]);
  assert.equal(await operation('lookup',{ id:request.id }),null);
});

test('adult acknowledgement requires age and cannot be submitted by a client RPC', async () => {
  const receipt = { userId:user,country:'US',noticeVersion:'2026-11-12-v3',termsAccepted:true,privacyAcknowledged:true };
  await assert.rejects(operation('adult',receipt), /acknowledgement required/);
  await assert.rejects(operation('adult',{...receipt,age:17}), /acknowledgement required/);
  assert.equal((await operation('adult',{...receipt,age:18})).account_kind,'adult');
  await assert.rejects(asUser("SELECT public.consent_service('adult',$1::jsonb)",[JSON.stringify({...receipt,age:18})]), /permission denied/);
});

test('parent-managed auth identities cannot add independent contact or OAuth credentials', async () => {
  await authorization('parent_managed');
  await assert.rejects(db.query('UPDATE auth.users SET email=$1 WHERE id=$2',['child@example.test',user]), /independent credentials/);
  await assert.rejects(db.query('UPDATE auth.users SET phone=$1 WHERE id=$2',['12345',user]), /independent credentials/);
  await db.query('UPDATE auth.users SET email=$1 WHERE id=$2',[`${user}@anon.ghostcopy.app`,user]);
  await assert.rejects(db.query("INSERT INTO auth.identities(user_id,provider,identity_data) VALUES($1,'google','{}')",[user]), /provider identities/);
  await db.query("INSERT INTO auth.identities(user_id,provider,identity_data) VALUES($1,'email',$2)",[user,JSON.stringify({email:`${user}@anon.ghostcopy.app`})]);
  await db.query('UPDATE auth.users SET email=$1 WHERE id=$2',['adult@example.test',other]);
});

test('withdrawn and unused child accounts have bounded retention including synthetic-email accounts', async () => {
  const request = await pending();
  await operation('apply_permissions',{ id:request.id,revision:request.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true });
  await operation('bind',{ claimHash:request.claim_hash,userId:user });
  await db.query("UPDATE auth.users SET email=$1,is_anonymous=false WHERE id=$2",[`${user}@anon.ghostcopy.app`,user]);
  await db.query("UPDATE public.cloud_authorizations SET status='revoked',updated_at=now()-interval '31 days' WHERE user_id=$1",[user]);
  assert.deepEqual(await operation('cleanup'),[request.id]);
  assert.equal((await db.query('SELECT count(*)::int AS n FROM auth.users WHERE id=$1',[user])).rows[0].n,0);
});

test('only a server-aged eligible account can graduate and its old guardian loses access', async () => {
  const request = await pending();
  await operation('apply_permissions',{ id:request.id,revision:request.revision,
    kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true });
  await operation('bind',{ claimHash:request.claim_hash,userId:user });
  await db.query("UPDATE private.parental_consent_requests SET age=17,created_at=now()-interval '1 year' WHERE id=$1",[request.id]);
  const adult = await operation('adult',{ userId:user,age:18,country:'CA',noticeVersion:'2026-11-12-v3',termsAccepted:true,privacyAcknowledged:true });
  assert.equal(adult.account_kind,'adult');
  assert.deepEqual(await operation('parent_list',{ parentHash:request.parent_hash }),[]);
  assert.deepEqual(await operation('cleanup'),[request.id]);
  assert.equal((await operation('profile',{userId:user})).status,'authorized');
});

test('a new verified guardian request cannot increase a known child age', async () => {
  const first = await pending();
  await operation('apply_permissions',{ id:first.id,revision:first.revision,kwsRequestId:first.kws_request_id,cloudSync:true,fileSync:false });
  await operation('bind',{ claimHash:first.claim_hash,userId:user });
  await operation('revoke',{id:first.id});
  const next = await operation('start',{claimHash:'a'.repeat(64),parentHash:'b'.repeat(64),age:17,country:'CA',noticeVersion:'2026-11-12-v3'});
  const sent = await operation('sent',{id:next.id,kwsRequestId:'new-request'});
  await operation('apply_permissions',{ id:sent.id,revision:sent.revision,kwsRequestId:sent.kws_request_id,cloudSync:true,fileSync:true });
  await assert.rejects(operation('bind',{claimHash:next.claim_hash,userId:user}), /age cannot be increased/);
  assert.equal((await operation('lookup',{userId:user})).id,first.id);
});

test('legacy guest data cannot silently become a supposedly encrypted child account', async () => {
  const request = await pending();
  await operation('apply_permissions',{id:request.id,revision:request.revision,kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true});
  await db.query("INSERT INTO public.clipboard(user_id,content) VALUES($1,'existing plaintext')",[user]);
  await assert.rejects(operation('bind',{claimHash:request.claim_hash,userId:user}), /new parent-managed account/);
  assert.equal(await operation('profile',{userId:user}),null);
});

test('repeated withdrawal or checks cannot extend the thirty-day deletion deadline', async () => {
  const request = await pending();
  await operation('apply_permissions',{id:request.id,revision:request.revision,kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true});
  await operation('bind',{claimHash:request.claim_hash,userId:user});
  await operation('revoke',{id:request.id});
  await db.query("UPDATE public.cloud_authorizations SET revoked_at=now()-interval '31 days' WHERE user_id=$1",[user]);
  await operation('revoke',{id:request.id});
  assert.deepEqual(await operation('cleanup'),[request.id]);
  assert.equal(await operation('profile',{userId:user}),null);
});

test('unchanged permission polling does not create repetitive consent audit records', async () => {
  let request = await pending();
  request = await operation('apply_permissions',{id:request.id,revision:request.revision,kwsRequestId:request.kws_request_id,cloudSync:false,fileSync:false});
  assert.equal((await db.query('SELECT count(*)::int AS n FROM private.consent_audit')).rows[0].n,0);
  for (let i=0;i<3;i++) request = await operation('apply_permissions',{id:request.id,revision:request.revision,kwsRequestId:request.kws_request_id,cloudSync:true,fileSync:true});
  assert.equal((await db.query('SELECT count(*)::int AS n FROM private.consent_audit')).rows[0].n,1);
});
