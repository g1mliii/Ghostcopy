import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';
import { after, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { setupConsentDatabase } from './consent_fixture.mjs';

// The parental notice version is stated once per language. A bump that misses
// one of them makes every child authorization fail closed, so they must match.
const root = new URL('../../', import.meta.url);
const read = (path) => readFile(new URL(path, root), 'utf8');

const compiled = stripTypeScriptTypes(await read('supabase/functions/_shared/kws.ts'), { mode: 'transform' });
const { parentalNoticeVersion } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`
);

const db = new PGlite();
after(() => db.close());

test('TypeScript, Dart and SQL state the same parental notice version', async () => {
  const dart = (await read('lib/services/distribution_consent_service.dart'))
    .match(/static const version = '([^']+)';/)?.[1];
  await setupConsentDatabase(db);
  const sql = (await db.query('SELECT private.notice_version() AS version')).rows[0].version;
  assert.match(parentalNoticeVersion, /^\d{4}-\d{2}-\d{2}-v\d+$/);
  assert.equal(dart, parentalNoticeVersion);
  assert.equal(sql, parentalNoticeVersion);
});

test('consent SQL reads the version only from private.notice_version()', async () => {
  const dir = new URL('supabase/migrations/', root);
  let mentions = 0;
  for (const name of await readdir(dir)) {
    if (!name.endsWith('.sql')) continue;
    mentions += (await readFile(new URL(name, dir), 'utf8')).split(`'${parentalNoticeVersion}'`).length - 1;
  }
  assert.equal(mentions, 1);
});

test('authenticated clients cannot call the private version function', async () => {
  await db.exec('SET ROLE authenticated');
  try {
    await assert.rejects(db.query('SELECT private.notice_version()'), /permission denied/);
  } finally {
    await db.exec('RESET ROLE');
  }
});
