import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

// The functions import their API keys from _shared/keys.ts, and the harnesses
// strip imports before running a function in a vm. Prepending the real helper,
// rather than stubbing publishableKey and friends, keeps the key handling
// itself under test - including the legacy fallback the fixtures rely on.
export const sharedKeysSource = stripTypeScriptTypes(
  (await readFile(new URL('../../supabase/functions/_shared/keys.ts', import.meta.url), 'utf8'))
    .replace(/^export /gm, ''),
);
